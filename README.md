A minecraft-inspired voxel engine written in Zig that renders entirely on the CPU. The project explores how far a software rasterizer can be pushed for voxel world:
chunked terrain, greedy meshing, multiple layers of frame primitive selection, tile-based multithreaded rasterization, perspective-correct texture sampling, mipmapping, player physics, collisions, block interaction, and more!

The renderer does not use GPU rasterization. SDL2 is used for windowing, input, and presenting a streaming ARGB8 framebuffer. 

Status: experimental engine / learning project. Some systems are still in development.

What is crazy is that for a rendering distance of  30 chunks, I get around 100FPS with my 7800X3D. CPUs are powerfull!

<img width="1922" height="1078" alt="2026-05-14-165510_hyprshot" src="https://github.com/user-attachments/assets/1f6541bd-5144-4099-ab13-48673d4dd184" />
<img width="1920" height="1080" alt="2026-05-12-164923_hyprshot" src="https://github.com/user-attachments/assets/6cbd4ba2-5aa6-4476-8e85-83a91ba79418" />



# Highlights
- **Fully software rasterized world renderer**
	- CPU-side projection, clipping, primitive binning, depth testing, texture sampling, and framebuffer writes.
	- SDL2 is used only to present the final framebuffer.
- **Tile based multithreaded rasterization**
	- Frame primitives are binned into screen-space tiles.
	- Worker threads rasterize independant tiles in batches.
	- Each tile owns its own color buffer and z-buffer, then writes back to the SDL texture framebuffer.
- **4..9-gon primitive support**
	- Chunk faces normally start as quads.
	- Near/frustum clipping can turn a quad into a polygon with up to 9 vertices.
	- Polygons are triangulated late using a fan during tile rasterization.
- **Juan Pineda-style edge-function rasterization**
	- Integer fixed-point on edge setup (for subpixel precision).
	- Top-left fill rule.
	- Conservative edge bias to reduce T-junction cracks.
- **Perspective correct texture interpolation**
	- Interpolates reciprocal depth and UV-over-depth.
	- Uses per-triangle derivatives to select mip levels.
	- Supports transparent texels by alpha-test discard.
- **Binary greedy meshing**
	- Solid voxel data is stored in axis-specific bitfield views.
	- Visible faces are extracted with bitwise masks.
	- Adjacent chunks are checked so shared internal faces are not emitted.
	- Coplanar compatible faces are merged into larger render quads.
- **Procedural terrain generation**
	- Deterministic value noise.
	- Fractal Brownian Motion terrain height.
- **Player controller and world interaction**
	- Mouse look.
	- Smooth ground/air accel and decel.
	- Axis-separated AABB collision detection and resolution against solid blocks.
	- DDA voxel raycast for block break/place.
	- Basic UI to select block to place.
- **Multiple levels of frame primitives selection**
	- Extraction of the frustum planes once a frame to discard chunks that are fully outside the frustum.
	- Bucket cull to reject whole face orientations for each chunk based on player positions.
	- Trivial primitive culling, then clipping against the 5 frustum planes (far plane excluded).
- **Debug instrumentation**
	Basic UI with a bitmap font that displays:
	- Chunk counters: loaded, active, visible, generating, meshing.
	- Triangle counters before/after bucket culling and clipping.
	- Player position, velocity, grounded state, FPS, and orientation gizmo.

Chunk management also happens on a separate thread. That was probably the hardest part of the project since I'am not familiar with advanced multithreading.

# Requirements
- Zig 0.16 compiler.
- SDL2 develpment package installed on your system.
- A platform capable of linking `sdl2` through the system linker.
- Maybe Linux (I don't have a windows machine to verify that everything is okay on Windows, MacOS should be fine).
- And of course, a powerful enough CPU and at least 8GB of RAM, through you can try to reduce resolution scale and simulation / load distance.

# Build and run
```
git clone https://github.com/Algorithmonaut/Rendering-engine-zig-SDL.git
cd Rendering-engine-zig-SDL
zig build --release=fast run
```

# Controls

| Input        | Action                 |
| ------------ | ---------------------- |
| Mouse        | Look around!           |
| RMB/LMB      | place/destroy blocks!  |
| Scroll wheel | Select block to place! |
| WASD         | Move!                  |
| Space        | Jump!                  |

# Project structure
```
.
├── build.zig
└── src
    ├── main.zig
    ├── Engine.zig
    ├── EngineConfig.zig
    ├── Renderer.zig
    ├── Framebuffer.zig
    ├── DDA.zig
    ├── constants.zig
    ├── helpers.zig
    ├── sky-gradient.zig
    ├── tile.zig
    ├── types.zig
    │
    ├── DS
    │   ├── SpscRingBuffer.zig
    │   └── SafeAutoHashMap.zig
    │
    ├── UI
    │   └── DebugOverlay.zig
    │
    ├── assets
    │   ├── text.zig
    │   ├── textures.zig
    │   └── textures-argb/
    │
    ├── game
    │   ├── Camera.zig
    │   └── Player.zig
    │
    ├── math
    │   ├── matrix.zig
    │   └── vector.zig
    │
    ├── mesh
    │   ├── Mesh.zig
    │   └── mesher.zig
    │
    ├── platform
    │   ├── sdl.h
    │   ├── SdlGraphics.zig
    │   └── SdlPlatform.zig
    │
    ├── renderer
    │   ├── Rasterizer.zig
    │   └── rasterization.zig
    │
    ├── tex
    │   └── atlas-builder.zig
    │
    └── world
        ├── ChunkManager.zig
        ├── ChunkWorker.zig
        ├── TerrainGenerator.zig
        ├── World.zig
        ├── chunk.zig
        ├── Lighting.zig
        └── lighting.zig
```

I will probably define more clearly the role of each file here when the project is finished.
