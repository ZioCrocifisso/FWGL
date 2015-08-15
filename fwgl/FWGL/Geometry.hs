{-# LANGUAGE GADTs, TypeOperators, KindSignatures, DataKinds,
             MultiParamTypeClasses #-}

module FWGL.Geometry (
        AttrList(..),
        Geometry(..),
        Geometry2,
        Geometry3,
        GPUBufferGeometry(..),
        GPUVAOGeometry(..),
        withGPUBufferGeometry,
        mkGeometry,
        mkGeometry2,
        mkGeometry3,
        castGeometry,
        facesToArrays,
        arraysToElements,
        triangulate
) where

import Control.Applicative
import Control.Monad.ST
import qualified Data.Hashable as H
import qualified Data.HashMap.Strict as H
import Data.Foldable (Foldable, forM_)
import Data.STRef
import qualified Data.Vector.Storable as V
import Data.Vect.Float hiding (Normal3)
import Data.Vect.Float.Instances ()
import Data.Word (Word16, Word)
import Unsafe.Coerce

import FWGL.Backend (BackendIO)
import FWGL.Internal.GL
import FWGL.Internal.Resource
import FWGL.Shader.CPU
import FWGL.Shader.Default2D (Position2)
import FWGL.Shader.Default3D (Position3, Normal3)
import qualified FWGL.Shader.Default2D as D2
import qualified FWGL.Shader.Default3D as D3
import FWGL.Shader.Language (size, ShaderType)
import FWGL.Transformation

-- | A heterogeneous list of attributes.
data AttrList (is :: [*]) where
        AttrListNil :: AttrList '[]
        AttrListCons :: (H.Hashable c, AttributeCPU c g, ShaderType g)
                     => (a -> g)
                     -> [c]
                     -> AttrList gs
                     -> AttrList (g ': gs)

-- | A set of attributes and indices.
data Geometry (is :: [*]) = Geometry (AttrList is) [Word16] Int

data GPUBufferGeometry = GPUBufferGeometry {
        attributeBuffers :: [(Buffer, GLUInt, GLUInt -> GL ())],
        elementBuffer :: Buffer,
        elementCount :: Int,
        geometryHash :: Int
}

data GPUVAOGeometry = GPUVAOGeometry {
        vaoBoundBuffers :: [Buffer],
        vaoElementCount :: Int,
        vao :: VertexArrayObject
}

-- | A 3D geometry.
type Geometry3 = '[Position3, D3.UV, Normal3]

-- | A 2D geometry.
type Geometry2 = '[Position2, D2.UV]

instance H.Hashable (AttrList is) where
        hashWithSalt salt AttrListNil = salt
        hashWithSalt salt (AttrListCons _ i is) = H.hashWithSalt salt (i, is)

instance H.Hashable (Geometry is) where
        hashWithSalt salt (Geometry _ _ h) = H.hashWithSalt salt h

instance Eq (Geometry is) where
        (Geometry _ _ h) == (Geometry _ _ h') = h == h'

instance H.Hashable GPUBufferGeometry where
        hashWithSalt salt = H.hashWithSalt salt . geometryHash

instance Eq GPUBufferGeometry where
        g == g' = geometryHash g == geometryHash g'

-- | Create a 3D 'Geometry'. The first three lists should have the same length.
mkGeometry3 :: GLES
            => [Vec3]   -- ^ List of vertices.
            -> [Vec2]   -- ^ List of UV coordinates.
            -> [Vec3]   -- ^ List of normals.
            -> [Word16] -- ^ Triangles expressed as triples of indices to the
                        --   three lists above.
            -> Geometry Geometry3
mkGeometry3 v u n = mkGeometry (AttrListCons D3.Position3 v $
                                AttrListCons D3.UV u $
                                AttrListCons D3.Normal3 n
                                AttrListNil)

-- | Create a 2D 'Geometry'. The first two lists should have the same length.
mkGeometry2 :: GLES
            => [Vec2]     -- ^ List of vertices.
            -> [Vec2]     -- ^ List of UV coordinates.
            -> [Word16] -- ^ Triangles expressed as triples of indices to the
                        --   two lists above.
            -> Geometry Geometry2
mkGeometry2 v u = mkGeometry (AttrListCons D2.Position2 v $
                              AttrListCons D2.UV u
                              AttrListNil)

-- | Create a custom 'Geometry'.
mkGeometry :: GLES => AttrList is -> [Word16] -> Geometry is
mkGeometry al e = Geometry al e $ H.hash al

castGeometry :: Geometry is -> Geometry is'
castGeometry = unsafeCoerce

instance (GLES, BackendIO) => Resource (Geometry i) GPUBufferGeometry GL where
        -- TODO: err check
        loadResource i f = loadGeometry i $ f . Right
        unloadResource _ = deleteGPUBufferGeometry

instance (GLES, BackendIO) => Resource GPUBufferGeometry GPUVAOGeometry GL where
        -- TODO: err check
        loadResource i f = loadGPUVAOGeometry i $ f . Right
        unloadResource _ = deleteGPUVAOGeometry

loadGPUVAOGeometry :: (GLES, BackendIO)
                    => GPUBufferGeometry
                    -> (GPUVAOGeometry -> GL ())
                    -> GL ()
loadGPUVAOGeometry g = asyncGL $
        do vao <- createVertexArray
           bindVertexArray vao
           (ec, bufs) <- withGPUBufferGeometry g $
                   \ec bufs -> bindVertexArray noVAO >> return (ec, bufs)
           return $ GPUVAOGeometry bufs ec vao

loadGeometry :: (GLES, BackendIO) 
             => Geometry i -> (GPUBufferGeometry -> GL ()) -> GL ()
loadGeometry (Geometry al es h) = asyncGL $
        GPUBufferGeometry <$> loadAttrList al
                          <*> (liftIO (encodeUShorts es) >>=
                                  loadBuffer gl_ELEMENT_ARRAY_BUFFER)
                          <*> pure (length es)
                          <*> pure h

loadAttrList :: GLES => AttrList is -> GL [(Buffer, GLUInt, GLUInt -> GL ())]
loadAttrList = loadFrom 0
        where loadFrom :: GLUInt -> AttrList is
                       -> GL [(Buffer, GLUInt, GLUInt -> GL ())]
              loadFrom _ AttrListNil = return []
              loadFrom i (AttrListCons g c al) =
                      (:) <$> loadAttribute i (g undefined) c
                          <*> loadFrom (i + fromIntegral (size $ g undefined))
                                       al
         
              loadAttribute i g c = do arr <- encodeAttribute g c
                                       buf <- loadBuffer gl_ARRAY_BUFFER arr
                                       return (buf, i, setAttribute g)

withGPUBufferGeometry :: GLES
                      => GPUBufferGeometry -> (Int -> [Buffer] -> GL a) -> GL a
withGPUBufferGeometry (GPUBufferGeometry abs eb ec _) f =
        do bindBuffer gl_ARRAY_BUFFER noBuffer
           (locs, bufs) <- unzip <$>
                   mapM (\(buf, loc, setAttr) ->
                                     do bindBuffer gl_ARRAY_BUFFER buf
                                        enableVertexAttribArray loc
                                        setAttr loc
                                        return (loc, buf)
                        ) abs

           bindBuffer gl_ELEMENT_ARRAY_BUFFER eb
           r <- f ec $ eb : bufs
           bindBuffer gl_ELEMENT_ARRAY_BUFFER noBuffer
           bindBuffer gl_ARRAY_BUFFER noBuffer
           -- mapM_ (disableVertexAttribArray . fromIntegral) locs
           return r

deleteGPUVAOGeometry :: GLES => GPUVAOGeometry -> GL ()
deleteGPUVAOGeometry (GPUVAOGeometry bufs _ vao) =
        do mapM_ deleteBuffer bufs
           deleteVertexArray vao


deleteGPUBufferGeometry :: GLES => GPUBufferGeometry -> GL ()
deleteGPUBufferGeometry (GPUBufferGeometry abs eb _ _) =
        mapM_ (\(buf, _, _) -> deleteBuffer buf) abs >> deleteBuffer eb

-- TODO: move
loadBuffer :: GLES => GLEnum -> Array -> GL Buffer
loadBuffer ty bufData =
        do buffer <- createBuffer
           bindBuffer ty buffer
           bufferData ty bufData gl_STATIC_DRAW
           bindBuffer ty noBuffer
           return buffer


arraysToElements :: Foldable f
                 => f (Vec3, Vec2, Vec3)
                 -> ([Vec3], [Vec2], [Vec3], [Word16])
arraysToElements arrays = runST $
        do vs <- newSTRef []
           us <- newSTRef []
           ns <- newSTRef []
           es <- newSTRef []
           triples <- newSTRef H.empty
           len <- newSTRef 0

           forM_ arrays $ \ t@(v, u, n) -> readSTRef triples >>= \ ts ->
                   case H.lookup t ts of
                           Just idx -> modifySTRef es (idx :)
                           Nothing -> do idx <- readSTRef len
                                         writeSTRef len $ idx + 1
                                         writeSTRef triples $ H.insert t idx ts
                                         modifySTRef vs (v :)
                                         modifySTRef us (u :)
                                         modifySTRef ns (n :)
                                         modifySTRef es (idx :)

           (,,,) <$> (reverse <$> readSTRef vs)
                 <*> (reverse <$> readSTRef us)
                 <*> (reverse <$> readSTRef ns)
                 <*> (reverse <$> readSTRef es)

facesToArrays :: V.Vector Vec3 -> V.Vector Vec2 -> V.Vector Vec3
              -> [[(Int, Int, Int)]] -> [(Vec3, Vec2, Vec3)]
facesToArrays ovs ous ons = (>>= toIndex . triangulate)
        where toIndex = (>>= \(v1, v2, v3) -> [ getVertex v1
                                              , getVertex v2
                                              , getVertex v3 ])
              getVertex (v, u, n) = (ovs V.! v, ous V.! u, ons V.! n)

triangulate :: [a] -> [(a, a, a)]
triangulate [] = error "triangulate: empty face"
triangulate (_ : []) = error "triangulate: can't triangulate a point"
triangulate (_ : _ : []) = error "triangulate: can't triangulate an edge"
triangulate (x : y : z : []) = [(x, y, z)]
triangulate (x : y : z : w : []) = [(x, y, z), (x, z, w)]
triangulate _ = error "triangulate: can't triangulate >4 faces"

instance H.Hashable Vec2 where
        hashWithSalt s (Vec2 x y) = H.hashWithSalt s (x, y)

instance H.Hashable Vec3 where
        hashWithSalt s (Vec3 x y z) = H.hashWithSalt s (x, y, z)

instance H.Hashable Vec4 where
        hashWithSalt s (Vec4 x y z w) = H.hashWithSalt s (x, y, z, w)
