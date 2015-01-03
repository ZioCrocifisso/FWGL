{-# LANGUAGE TypeOperators, DataKinds, ConstraintKinds,
             TypeFamilies, FlexibleContexts #-}

module FWGL.Graphics.Custom (
        module FWGL.Vector,
        Layer,
        Object,
        Geometry,
        Texture,
        Color(..),
        (~~),
        nothing,
        static,
        global,
        globalDraw,
        globalTexture,
        layer,
        unsafeJoin,
        mkGeometry,
        mkTexture,
        textureURL,
        colorTex
) where

import Data.Typeable
import FRP.Yampa
import FWGL.Backend (BackendIO, GLES)
import FWGL.Geometry
import FWGL.Graphics.Color
import FWGL.Graphics.Draw
import FWGL.Graphics.Types
import FWGL.Internal.GL (GLES, ActiveTexture)
import FWGL.Internal.TList
import FWGL.Shader.CPU
import FWGL.Shader.Program
import FWGL.Texture
import FWGL.Vector

-- | An empty custom object.
nothing :: Object '[] '[]
nothing = ObjectEmpty

-- | A custom object with a specified 'Geometry'
static :: Geometry i -> Object '[] i
static = ObjectMesh . StaticGeom

-- | Sets a global (uniform) of an object
global :: (Typeable g, UniformCPU c g) => g -> c
       -> Object gs is -> Object (g ': gs) is
global g c = globalDraw g $ return c

-- | Sets a global (uniform) of an object
globalDraw :: (Typeable g, UniformCPU c g) => g -> Draw c
           -> Object gs is -> Object (g ': gs) is
globalDraw = ObjectGlobal

-- | Sets a global (uniform) of an object using a Texture
globalTexture :: (BackendIO, Typeable g, UniformCPU ActiveTexture g)
              => g -> Texture -> Object gs is -> Object (g ': gs) is
globalTexture g c = globalDraw g $ textureUniform c

-- | Join two objects.
(~~) :: (Equal gs gs', Equal is is')
     => Object gs is -> Object gs' is'
     -> Object (Union gs gs') (Union is is')
(~~) = ObjectAppend

-- | Join two objects, even if they don't provide the same variables.
unsafeJoin :: (Equal gs'' (Union gs gs'), Equal is'' (Union is is'))
           => Object gs is -> Object gs' is' -> Object gs'' is''
unsafeJoin = ObjectAppend

-- | Associate an object with a program.
layer :: (Subset oi pi, Subset og pg)
      => Program pg pi -> Object og oi -> Layer
layer = Layer

-- | Generate a 1x1 texture.
colorTex :: GLES => Color -> Texture
colorTex c = mkTexture 1 1 [ c ]
