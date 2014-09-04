{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module FWGL.Graphics.Draw (
        Draw,
        DrawState,
        execDraw,
        drawInit,
        drawBegin,
        drawScene,
        resize
) where

import FWGL.Graphics.Shapes
import FWGL.Graphics.Types
import FWGL.Vector

import JavaScript.WebGL hiding (getCtx)

import qualified Data.HashMap.Strict as H
import Data.Word (Word, Word16)
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.Trans.State
import GHCJS.Foreign
import GHCJS.Marshal
import GHCJS.Types

data DrawState = DrawState {
        context :: Ctx,
        cubeBuffers :: GPUMesh, -- TODO: subst gpuMeshes
        modelUniform :: UniformLocation,
        gpuMeshes :: H.HashMap Geometry GPUMesh
}

newtype Draw a = Draw { unDraw :: StateT DrawState IO a }
        deriving (Functor, Applicative, Monad, MonadIO)

data GPUMesh = GPUMesh {
        vertexBuffer :: Buffer,
        uvBuffer :: Buffer,
        normalBuffer :: Buffer,
        elementBuffer :: Buffer,
        elementCount :: Int
}

drawInit :: Ctx -> Int -> Int -> IO DrawState
drawInit ctx w h = do program <- loadShaders ctx defVS defFS
                      enable ctx gl_DEPTH_TEST
                      depthFunc ctx gl_LESS
                      clearColor ctx 0.0 0.0 0.0 1.0
                      resizeIO ctx w h
                      cube <- loadGeometry ctx cubeGeometry
                      modelUniform <- getUniformLocation ctx program
                                                $ toJSString "modelMatrix"
                      return DrawState { context = ctx
                                       , cubeBuffers = cube
                                       , modelUniform = modelUniform
                                       , gpuMeshes = H.empty }

execDraw :: Draw () -> DrawState -> IO DrawState
execDraw (Draw a) = execStateT a

resize :: Int -> Int -> Draw ()
resize w h = getCtx >>= \ctx -> liftIO $ resizeIO ctx w h

resizeIO :: Ctx -> Int -> Int -> IO ()
resizeIO ctx w h = viewport ctx 0 0 w h

drawBegin :: Draw ()
drawBegin = getCtx >>= \ctx -> liftIO $ clear ctx gl_COLOR_BUFFER_BIT

drawScene :: Scene -> Draw ()
drawScene = mapM_ drawObject

drawObject :: Object -> Draw ()
drawObject (SolidObject s) = drawSolid s

drawSolid :: Solid -> Draw ()
drawSolid (Solid mesh trans) =
        do ctx <- getCtx
           modelUni <- Draw $ modelUniform <$> get
           liftIO $ do matarr <- encodeM4 trans
                       uniformMatrix4fv ctx modelUni False matarr
           drawMesh mesh

drawMesh :: Mesh -> Draw ()
drawMesh Empty = return ()
drawMesh Cube = Draw (cubeBuffers <$> get) >>= drawGPUMesh
drawMesh (StaticGeom g) = getGPUMesh g >>= drawGPUMesh
drawMesh (DynamicGeom d g) = disposeGeometry d >> drawMesh (StaticGeom g)

getGPUMesh :: Geometry -> Draw GPUMesh
getGPUMesh g = do map <- Draw $ gpuMeshes <$> get
                  case H.lookup g map of
                          Just gpuMesh -> return gpuMesh
                          Nothing -> do ctx <- getCtx
                                        gpuMesh <- liftIO $ loadGeometry ctx g
                                        Draw . modify $ \ s -> s {
                                                gpuMeshes =
                                                        H.insert g gpuMesh map
                                                }
                                        return gpuMesh

drawGPUMesh :: GPUMesh -> Draw ()
drawGPUMesh (GPUMesh vb _ nb eb ec) = getCtx >>= \ctx -> liftIO $
        do bindBuffer ctx gl_ARRAY_BUFFER vb
           enableVertexAttribArray ctx posAttribLoc
           vertexAttribPointer ctx posAttribLoc 3 gl_FLOAT False 0 0
           bindBuffer ctx gl_ARRAY_BUFFER nb
           enableVertexAttribArray ctx normalAttribLoc
           vertexAttribPointer ctx normalAttribLoc 3 gl_FLOAT False 0 0
           bindBuffer ctx gl_ARRAY_BUFFER noBuffer

           bindBuffer ctx gl_ELEMENT_ARRAY_BUFFER eb
           drawElements ctx gl_TRIANGLES ec gl_UNSIGNED_SHORT 0
           bindBuffer ctx gl_ELEMENT_ARRAY_BUFFER noBuffer

           disableVertexAttribArray ctx posAttribLoc
           disableVertexAttribArray ctx normalAttribLoc

getCtx :: Draw Ctx
getCtx = Draw $ context <$> get

loadGeometry :: Ctx -> Geometry -> IO GPUMesh
loadGeometry ctx (Geometry vs fs ns es _) =
        GPUMesh <$> (viewV3 vs >>= loadBuffer ctx gl_ARRAY_BUFFER)
                <*> (viewV2 fs >>= loadBuffer ctx gl_ARRAY_BUFFER)
                <*> (viewV3 ns >>= loadBuffer ctx gl_ARRAY_BUFFER)
                <*> (viewWord16 es >>= loadBuffer ctx gl_ELEMENT_ARRAY_BUFFER)
                <*> (pure $ length es)

disposeGeometry :: Geometry -> Draw ()
disposeGeometry g = do gpuMesh <- getGPUMesh g
                       ctx <- getCtx
                       liftIO $ deleteGPUMesh ctx gpuMesh
                       Draw . modify $ \ s -> s {
                                gpuMeshes = H.delete g $ gpuMeshes s
                       }

deleteGPUMesh :: Ctx -> GPUMesh -> IO ()
deleteGPUMesh ctx (GPUMesh vb ub nb eb _) = do deleteBuffer ctx vb
                                               deleteBuffer ctx ub
                                               deleteBuffer ctx nb
                                               deleteBuffer ctx eb

encodeM4 :: M4 -> IO Float32Array
encodeM4 (M4 (V4 a1 a2 a3 a4)
             (V4 b1 b2 b3 b4)
             (V4 c1 c2 c3 c4)
             (V4 d1 d2 d3 d4) ) = listToJSArray [ a1, a2, a3, a4
                                                , b1, b2, b3, b4
                                                , c1, c2, c3, c4
                                                , d1, d2, d3, d4 ]
                                  >>= float32Array

viewV3 :: [V3] -> IO ArrayBufferView
viewV3 v = toJSArray next (0, v) >>= float32View
        where next (0, xs@(V3 x _ _ : _)) = Just (x, (1, xs))
              next (1, xs@(V3 _ y _ : _)) = Just (y, (2, xs))
              next (2, V3 _ _ z : xs) = Just (z, (0, xs))
              next (_, []) = Nothing

viewV2 :: [V2] -> IO ArrayBufferView
viewV2 v = toJSArray next (False, v) >>= float32View
        where next (False, xs@(V2 x _ : _)) = Just (x, (True, xs))
              next (True, V2 _ y : xs) = Just (y, (False, xs))
              next (_, []) = Nothing

viewWord16 :: [Word16] -> IO ArrayBufferView
viewWord16 v = listToJSArray v >>= uint16View

toJSArray :: ToJSRef a => (v -> Maybe (a, v)) -> v -> IO (JSArray a)
toJSArray next iv = newArray >>= iterPush iv
        where iterPush v arr = case next v of
                                        Just (x, v') -> do xRef <- toJSRef x
                                                           pushArray xRef arr
                                                           iterPush v' arr
                                        Nothing -> return arr

listToJSArray :: ToJSRef a => [a] -> IO (JSArray a)
listToJSArray = toJSArray deconstr
        where deconstr (x : xs) = Just (x, xs)
              deconstr [] = Nothing

loadBuffer :: Ctx -> Word -> ArrayBufferView -> IO Buffer
loadBuffer ctx ty bufData =
        do buffer <- createBuffer ctx
           bindBuffer ctx ty buffer
           bufferData ctx ty bufData gl_STATIC_DRAW
           bindBuffer ctx ty noBuffer
           return buffer

loadShaders :: Ctx -> String -> String -> IO Program
loadShaders ctx vsSrc fsSrc =
        do program <- createProgram ctx
           vs <- loadShader ctx gl_VERTEX_SHADER vsSrc 
           fs <- loadShader ctx gl_FRAGMENT_SHADER fsSrc 
           attachShader ctx program vs
           attachShader ctx program fs
           bindAttribLocation ctx program posAttribLoc $ toJSString "pos"
           bindAttribLocation ctx program normalAttribLoc $ toJSString "normal"
           linkProgram ctx program
           useProgram ctx program
           return program

posAttribLoc :: Num a => a
posAttribLoc = 0

normalAttribLoc :: Num a => a
normalAttribLoc = 1

loadShader :: Ctx -> Word -> String -> IO Shader
loadShader ctx ty src =
        do shader <- createShader ctx ty
           shaderSource ctx shader $ toJSString src
           compileShader ctx shader
           return shader

defVS :: String
defVS = "       attribute vec3 pos;                                     \
        \       attribute vec3 normal;                                  \
        \       varying vec4 vpos;                                      \
        \       uniform mat4 modelMatrix;                               \
        \       void main() {                                           \
        \               vpos = vec4(pos, 1.0);                          \
        \               gl_Position = modelMatrix * vpos;               \
        \       }                                                       "

defFS :: String
defFS = "       precision mediump float;                                \
        \       varying vec4 vpos;                                      \
        \       varying vec3 vnormal;                                   \
        \       void main() {                                           \
        \               gl_FragColor = vpos / 2.0 + 0.5;                \
        \       }                                                       "
