A minecraft-inspired massively optimized voxel engine written in Zig that renders entirely on the CPU. The project explores how far a software rasterizer can be pushed for voxel world:
chunked terrain, greedy meshing, multiple layers of frame primitive selection, tile-based multithreaded rasterization, perspective-correct texture sampling, mipmapping, player physics, collisions, block interaction, and more!

The renderer does not use GPU rasterization. SDL2 is used for windowing, input, and presenting a streaming ARGB8 framebuffer. 

Status: experimental engine / learning project. Some systems are still in development.

___

# Disclaimer

My intention with this project was to learn how to have a scientific approach while designing systems. Yet:
- The performance impact of the features / feature iterations wasn't efficiently measured.
- The codebase wasn't tested and validated.
- My findings weren't properly documented.

It is fair to say that doing such a large project trained me to:
- design a large system
- integrate many subsystems
- debug difficult rendering and concurrency problems
- persist through a long project
  
*But* merely keeping the whole system operational consumed most of my attention, and prevented me from developing a disciplined experimental workflow.
___

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
git clone https://github.com/Algorithmonaut/software-rasterized-voxel-engine.git
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

___

# **Below is described how I plan to reject occluded geometry in bulk. This will probably massively improve performance once implemented.**

# Problem

Around $90$% of all the geometry in the scene of my voxel engine is occluded at any time. We want to find a way to easily reject such geometry without having to:

- Decode each compressed quad descriptor into its four world-space vertices, material information, texture coordinates, and other per-primitive data.
- Transform the vertices into clip space, perform near-plane and viewport clipping, and compute the projected screen-space bounds.
- Run primitive setup, insert the quad or its triangles into tile bins, and evaluate their fragments, *only for the existing depth buffer values to reject every covered pixel*.

# Core idea 

The viewport is subdivided into $8 \times 8$ tiles $T$ holding their own frambuffer, z-buffer, winning primitive buffer, coverage bitset, and a scalar indicating the fragment with the furthest depth drawn to the tile at any time:
```zig
TILE_SIZE = 8;
const PrimitiveId = u32;

const Tile = struct {
    frame_buffer: [TILE_SIZE * TILE_SIZE]u32,
    depth_buffer: [TILE_SIZE * TILE_SIZE]f32,
    winner_buffer: [TILE_SIZE * TILE_SIZE]PrimitiveId,
    converage: u64,
    furthest_q: f32,
}
```

Here $q = 1 / w$: larger values are closer ($w$ is the depth of any point relative to the camera angle).

At a given sampling position (pixel), when a fragment passes the depth test, we:

- Record its color and its depth on the framebuffer and depth-buffer respectively.
- Record the primitive that won the pixel in the winner buffer.
- Set the coverage bit corresponding to the pixel index to $1$.
- Set `furthest_q = @min(furthest_q, q)`.

The `coverage` bitset removes the need to clear the `depth_buffer` and `winner_buffer` at the end of each frame, instead we can simply:

- Clear the `converage` bitset at the end of each frame.
- Probe the bit associated to a position $P$ to know if the value at position $P$ belongs to the current frame.

This could reduce frame time up to 0.5ms (i.e. the average of frame clear time according to the profiler).

But most importantly, the `coverage` bitset is a form of *Hi-Z* (hierarchical depth buffer):



## Fast rejection of hierarchical world nodes using *Hi-Z*

Once all $64$ pixels of the tile $T$ are covered (i.e. when `converage` $= \underbrace{\text{11...1}}_{\text{64 times}})$:

$$q_{far}(T) = min_{p \in T}q(p)$$

For a world hierarchy node $N$ (i.e. a chunk or a compact superset of chunks), we calculate a conservative closest possible reciprocal depth:
$$q_{near}(N) = max_{x \in N}\ \frac{1}{w(x)}$$

Because $w$ is affine over an axis-aligned bounding-box (AABB), and the node is entirely in front of the near plane, this can be bounded from its eight corners.

The node is occluded over a tile when:

$$(q_{near}(N) \leq q_{far}(T))\ \land (\text{coverage} = \underbrace{\text{11...1}}_{\text{64 times}})$$

Thus, the entire node can be skipped for the tile.

## Covering tiles *quickly*

We must find a way such that as many tiles as possible are fully covered with valid geometry, while minimizing the work needed to arrive at such state.

A good strategy is to record all the geometry that was visible (i.e. non-occluded) at frame $n -1$, and draw it first. Let's call them *winning primitives*.

Then, we can traverse the world hierarchy, recursively descend the node tree and find the smallest nodes that are projected within the bounds of a tile whose coverage bitset isn't maximized, and render the geometry of the node to complete the image.

With this method, many nodes can be quickly rejected, thus reducing the frame-time that would otherwise be taken by building and processing their render primitives.


# Recording winning primitives

To record the winning primitives of a frame, we must know per-final-pixel the `id` of the primitive painted at that pixel. Simply recording all the primitives that have been drawn to at least one pixel is insufficient because it doesn't account for overdraw.

After all tiles have finished, we scan every primitive-owner (winning) buffer into one global bitset where the bit at position `id` indicate that the primitive with id `id` is a winning primitive:
```zig
inline fn markPrimitive(visible_bits: []u64, primitive_id: u32) void {
    const id: usize = @intCast(primitive_id);
    const word_i = id >> 6;
    const bit_i: u6 = @intCast(id & 63);

    visible_bits[word_i] |= @as(u64, 1) << bit_i;
}
```
We set `NO_PRIMITIVE = std.math.maxInt(u32)`, so the last used bit of the last word should be ignored.

## Resolving winning primitives *in parallel*
To avoid cache-line ping-pong, each worker owns a `visible_bits` array (instead of using atomics).

After processing each tile, while its $8 \times 8$ owner buffer is still hot in cache:
```zig
for (tile.primitive_id_buf) |primitive_id|
    markPrimitive(worker_visible_bits, primitive_id);
```


Then, we combine the worker's `visible_bits` arrays on the main thread:
```zig
@memset(global_visible_bits, 0);

for (worker_visible_bits) |worker_bits| {
    for (global_visible_bits, worker_bits) |*global, local| 
        global.* |= local
}
```

# Calculating winners each frame is redundant
If the scene  hasn't changed much, recomputing the winning primitives will not yield a big performance advantage. Instead, we proceed as follow:

1. Capture the exact winner set on a sampling frame.
2. Keep displaying that result unchanged.
3. Accumulate camera rotation, movement and world changes since that sample.
4. Capture a new winner set once a threashold is reached.

## Reasonable initial thresholds 

For rotation, with a vertical FOV of 90°, a threashold of 22.5° is approximately a seventh of the horizontal FOV (assuming 16:9). The winner set will have changed materially by then, which is exactly when another sample becomes useful.

For displacement, we want to measure net displacement: `distance(camera_position, sampled_position)`. A distance of four blocks seems reasonable as the threshold.

For world changes, we increment a revision counter when world geometry changes (i.e. remeshing, loading/unloading, placing/destroying blocks): `world_revision += 1`. The threashold is a single increment to avoid stale geometry. PROBLEM: Remeshing cost + winners recomputation with probably cause very low 1% fps.

## Another lazy way

Chunks already have stable identities and the renderer already calculate the visible chunks set every frame. 

Let $C_{ref}$ be the set of visible chunks at a sampling frame and $C$ the set of visible chunks on following frames. We compute the overlap of both sets:

- `removed` $\ = C \setminus C_{ref}$
- `added` $\ = C_{ref} \setminus C$

This is easy algorithmically because the chunks are already sorted front-to-back.
Then we trigger a new calculation of winning primitives when the change ratio is greater than e.g. $20\%$.

This reduces interdependence, but is a more expensive invalidation heuristic.

___

We can then feed the *winning geometry* to the next frame, thus allowing most occluded geometry to be discarded in bulk.

