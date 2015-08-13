{-# LANGUAGE DataKinds, FlexibleContexts, ConstraintKinds, TypeOperators,
             TypeFamilies #-}

{-| Simplified 2D graphics system. -}
module FWGL.Graphics.D2 (
        -- * Elements
        Element,
        rect,
        image,
        depth,
        sprite,
        -- ** Geometry
        Geometry,
        Geometry2,
        geom,
        mkGeometry2,
        -- * Textures
        module FWGL.Graphics.Color,
        Texture,
        C.textureURL,
        C.textureFile,
        C.colorTex,
        mkTexture,
        -- * Transformations
        Vec2(..),
        pos,
        rot,
        scale,
        scaleV,
        transform,
        -- * Layers
        Layer,
        C.combineLayers,
        -- ** Element layers
        elements,
        view,
        -- ** Object layers
        Program,
        layer,
        layerPrg,
        C.program,
        defaultProgram2D,
        -- ** Sublayers
        C.subLayer,
        C.depthSubLayer,
        C.subRenderLayer,
        -- *** Render layers
        RenderLayer,
        renderColor,
        renderDepth,
        renderColorDepth,
        renderColorInspect,
        renderDepthInspect,
        renderColorDepthInspect,
        -- * Custom 2D objects
        Object,
        object,
        object1,
        object1Image,
        object1Depth,
        object1Trans,
        object1ImageDepth,
        object1ImageTrans,
        object1DepthTrans,
        (C.~~),
        -- ** Globals
        C.global,
        C.globalTexture,
        C.globalTexSize,
        viewObject,
        DefaultUniforms2D,
        Image(..),
        Depth(..),
        Transform2(..),
        View2(..),
        -- * Vectors and matrices
        module Data.Vect.Float,
        -- ** Transformation matrices
        transMat3,
        rotMat3,
        scaleMat3
) where

import Control.Applicative
import Data.Vect.Float
import FWGL.Backend hiding (Texture, Image, Program)
import FWGL.Geometry
import qualified FWGL.Graphics.Custom as C
import FWGL.Graphics.Color
import FWGL.Graphics.Draw
import FWGL.Graphics.Shapes
import FWGL.Graphics.Types hiding (program)
import FWGL.Graphics.Texture
import FWGL.Internal.TList
import FWGL.Shader.Default2D (Image, Depth, Transform2, View2)
import FWGL.Shader.Program
import FWGL.Transformation

-- | A 2D object with a 'Texture', a depth and a transformation.
data Element = Element Float Texture (Draw Mat3) (Geometry Geometry2)

-- | A rectangle with a specified 'Texture' and size.
rect :: GLES => Vec2 -> Texture -> Element
rect v t = Element 0 t (return idmtx) $ rectGeometry v

-- | An element with a specified 'Geometry' and 'Texture'.
geom :: Texture -> Geometry Geometry2 -> Element
geom t = Element 0 t $ return idmtx

-- | A rectangle with the aspect ratio adapted to its texture.
image :: BackendIO
      => Float          -- ^ Width.
      -> Texture -> Element
image s t = Element 0 t ((\(w, h) -> scaleMat3 (Vec2 1 $ h /w)) <$>
                                     textureSize t)
                        (rectGeometry $ Vec2 s s)

-- | Set the depth of an element.
depth :: Float -> Element -> Element
depth d (Element _ t m g) = Element d t m g

-- | A rectangle with the size and aspect ratio adapted to the screen. You
-- have to use the 'FWGL.Utils.screenScale' view matrix.
sprite :: BackendIO => Texture -> Element
sprite t = Element 0 t ((\(w, h) -> scaleMat3 $ Vec2 w h) <$> textureSize t)
                       (rectGeometry $ Vec2 1 1)

-- | Create a graphical 'Object' from a list of 'Element's and a view matrix.
object :: BackendIO => Mat3 -> [Element] -> Object DefaultUniforms2D Geometry2
object m = viewObject m . foldl acc ObjectEmpty
        where acc o e = o C.~~ object1 e

-- | Create a graphical 'Object' from a single 'Element'. This lets you set your
-- own globals individually. If the shader uses the view matrix 'View2' (e.g.
-- the default 2D shader), you have to set it with 'viewObject'.
object1 :: BackendIO => Element -> Object '[Image, Depth, Transform2] Geometry2
object1 (Element d t m g) = C.globalTexture (undefined :: Image) t $
                            C.global (undefined :: Depth) d $
                            C.globalDraw (undefined :: Transform2) m $
                            C.geom g

-- | Like 'object1', but it will only set the image.
object1Image :: BackendIO => Element -> Object '[Image] Geometry2
object1Image (Element _ t _ g) = C.globalTexture (undefined :: Image) t $
                                 C.geom g

-- | Like 'object1', but it will only set the depth.
object1Depth :: BackendIO => Element -> Object '[Depth] Geometry2
object1Depth (Element d _ _ g) = C.global (undefined :: Depth) d $
                                 C.geom g

-- | Like 'object1', but it will only set the transformation matrix.
object1Trans :: BackendIO => Element -> Object '[Transform2] Geometry2
object1Trans (Element _ _ m g) = C.globalDraw (undefined :: Transform2) m $
                                 C.geom g

-- | Like 'object1', but it will only set the image and the depth.
object1ImageDepth :: BackendIO => Element -> Object '[Image, Depth] Geometry2
object1ImageDepth (Element d t _ g) = C.globalTexture (undefined :: Image) t $
                                      C.global (undefined :: Depth) d $
                                      C.geom g

-- | Like 'object1', but it will only set the image and the transformation
-- matrix.
object1ImageTrans :: BackendIO => Element 
                  -> Object '[Image, Transform2] Geometry2
object1ImageTrans (Element _ t m g) = C.globalTexture (undefined :: Image) t $
                                      C.globalDraw (undefined :: Transform2) m $
                                      C.geom g

-- | Like 'object1', but it will only set the depth and the transformation
-- matrix.
object1DepthTrans :: BackendIO => Element
                  -> Object '[Depth, Transform2] Geometry2
object1DepthTrans (Element d _ m g) = C.global (undefined :: Depth) d $
                                      C.globalDraw (undefined :: Transform2) m $
                                      C.geom g

-- | Create a standard 'Layer' from a list of 'Element's.
elements :: BackendIO => [Element] -> Layer
elements = layer . object idmtx

-- | Create a 'Layer' from a view matrix and a list of 'Element's.
view :: BackendIO => Mat3 -> [Element] -> Layer
view m = layer . object m

-- | Set the value of the view matrix of a 2D 'Object'.
viewObject :: BackendIO => Mat3 -> Object gs Geometry2
           -> Object (View2 ': gs) Geometry2
viewObject = C.global (undefined :: View2)

-- | Create a 'Layer' from a 2D 'Object', using the default shader.
layer :: BackendIO => Object DefaultUniforms2D Geometry2 -> Layer
layer = layerPrg defaultProgram2D

-- | Create a 'Layer' from a 2D 'Object', using a custom shader.
layerPrg :: (BackendIO, Subset og pg) => Program pg Geometry2
         -> Object og Geometry2 -> Layer
layerPrg = C.layer

-- | Translate an 'Element'.
pos :: Vec2 -> Element -> Element
pos v = transform $ transMat3 v

-- | Rotate an 'Element'.
rot :: Float -> Element -> Element
rot a = transform $ rotMat3 a

-- | Scale an 'Element'.
scale :: Float -> Element -> Element
scale f = transform $ scaleMat3 (Vec2 f f)

-- | Scale an 'Element' in two dimensions.
scaleV :: Vec2 -> Element -> Element
scaleV v = transform $ scaleMat3 v

-- | Transform an 'Element'.
transform :: Mat3 -> Element -> Element
transform m' (Element d t m g) = Element d t (flip (.*.) m' <$> m) g
