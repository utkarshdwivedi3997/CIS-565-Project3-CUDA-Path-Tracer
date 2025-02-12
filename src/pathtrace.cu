#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>
#include <thrust/functional.h>
#include <thrust/device_ptr.h>
#include <stdio.h>
#include <iostream>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "glm/common.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

#pragma region HELPERS
__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

struct notEquals
{
private:
	const int _a;
public:
	notEquals(int a) : _a(a)
	{}

	__host__ __device__ bool operator()(const PathSegment& x)
	{
		return x.remainingBounces != _a;
	}
};

struct sortByMaterialId
{
	__host__ __device__ bool operator()(const Intersection& isect1, const Intersection& isect2)
	{
		return isect1.materialId < isect2.materialId;
	}
};

// Sample square to disc concentric
__host__ __device__ glm::vec3 squareToDiskConcentric(glm::vec2 xi) {
	float theta, radius;

	// Map values to [-1,1]
	glm::vec2 s = (2.0f * xi) - glm::vec2(1.0f);
	if (s.x == 0 && s.y == 0)
	{
		// we don't really need to do this check since our sampled points will rarely, if ever, be at the very origin
		// but the book does it, and this makes the center of the "grid" appear properly, so I'm doing this here too
		return glm::vec3(0, 0, 0);
	}

	if (glm::abs(s.x) > glm::abs(s.y))
	{
		radius = s.x;
		theta = PI_OVER_4 * (s.y / s.x);   // pi/4 * s.y/s.x
	}
	else
	{
		radius = s.y;
		theta = PI_OVER_2 - (PI_OVER_4 * (s.x / s.y));
	}

	return glm::vec3(cos(theta) * radius, sin(theta) * radius, 0);
}

/// <summary>
/// Transforms the point from local camera space to world space
/// </summary>
/// <param name="cam"></param>
/// <returns></returns>
__host__ __device__ void cameraToWorld(glm::vec3 &p, const Camera& cam)
{
	glm::mat3 rot = glm::mat3(cam.right, cam.up, cam.view);
	p = cam.position + rot * p;
}

#pragma endregion

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

#if ENABLE_HDR_GAMMA_CORRECTION
		// Apply the Reinhard operator and gamma correction
		// before outputting color.
		pix = (pix / (pix + glm::vec3(1.0f)));						// Reinhard operator
		pix = glm::pow(pix, glm::vec3(1.0 / GAMMA));                 // Gamma correction
#endif

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x* 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static Intersection* dev_intersections = NULL;
static Triangle* dev_tris = NULL;
static BVHNode* dev_bvhNodes = NULL;

// TODO: static variables for device memory, any extra info you need, etc
// ...

#if CACHE_FIRST_INTERSECTION
static Intersection* dev_cached_intersections = NULL;
#endif

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_tris, scene->tris.size() * sizeof(Triangle));
	cudaMemcpy(dev_tris, scene->tris.data(), scene->tris.size() * sizeof(Triangle), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_bvhNodes, scene->bvhNodes.size() * sizeof(BVHNode));
	cudaMemcpy(dev_bvhNodes, scene->bvhNodes.data(), scene->bvhNodes.size() * sizeof(BVHNode), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(Intersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(Intersection));

	// TODO: initialize any extra device memeory you need

#if CACHE_FIRST_INTERSECTION
	cudaMalloc(&dev_cached_intersections, pixelcount * sizeof(Intersection));
	cudaMemset(dev_cached_intersections, 0, pixelcount * sizeof(Intersection));
#endif

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_tris);
	cudaFree(dev_bvhNodes);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	// TODO: clean up any extra device memory you created

#if CACHE_FIRST_INTERSECTION
	cudaFree(dev_cached_intersections);
#endif

	checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(0.0, 0.0, 0.0);
		segment.accum_throughput = glm::vec3(1.0, 1.0, 1.0);

		// randomly offset the ray directions slightly for anti-aliasing
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, traceDepth);
		thrust::uniform_real_distribution<float> u01(0, 1);

		// jitter for AA
		float xOffset = 0;
		float yOffset = 0;

#if !CACHE_FIRST_INTERSECTION		// anti-aliasing will only work when first bounce is not cached
		xOffset = u01(rng);
		yOffset = u01(rng);
#endif

		glm::vec3 dir = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x + xOffset - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y + yOffset - (float)cam.resolution.y * 0.5f)
		);

		if (cam.apertureSize > 0.0f)	// thin-lens model
		{
			// ray-plane intersection
			float focalT = cam.focalLength * glm::dot(cam.view, cam.view) / glm::dot(dir, cam.view);
			glm::vec3 focalPt = cam.position + focalT * dir;

			glm::vec3 ptOnLens = cam.apertureSize * squareToDiskConcentric(glm::vec2(u01(rng), u01(rng)));	// random point in lens in local camera space
			
			cameraToWorld(ptOnLens, cam);	// convert pt to world space

			segment.ray.origin = ptOnLens;
			dir = glm::normalize(focalPt - ptOnLens);
		}

		segment.ray.direction = dir;

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, int geoms_size
	, Triangle* tris
	, int tri_size
	, BVHNode* bvhNodes
	, int bvhNodes_size
	, Intersection* intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == GLTF_MESH)
			{
				t = geomIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, tris, bvhNodes);
			}

			// TODO: add more intersection tests here... triangle? metaball? CSG?

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

__global__ void kernel_sample_f(int iter,
								int depth,
								int num_paths, 
								Intersection* isects, 
								PathSegment* paths,
								Material* mats)
{
	int idx = (blockDim.x * blockIdx.x) + threadIdx.x;

	if (idx >= num_paths)
	{
		return;		// invalid index
	}

	Intersection isect = isects[idx];
	PathSegment &path = paths[idx];

	if (path.remainingBounces == 0)
	{
		return;
	}

	if (isect.t > 0.0f)	// there was an intersection
	{
		Material mat = mats[isect.materialId];
		
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, depth);

		if (mat.emittance > 0.0f)
		{
			// this is a light source
			// light is multiplicative, not additive.
			path.color = mat.color * mat.emittance * path.accum_throughput;		// Le + accumulated integral
			path.remainingBounces = 0;	// this is the light source, stop pathtracing
		}
		else
		{
			glm::vec3 p = getPointOnRay(path.ray, isect.t);
			sample_f(path, p, isect.surfaceNormal, mat, rng);
		}

		// POTENTIAL TODO: might need to refactor the entire Material struct + data parsing
		// if I do any more complex materials
	}
	else
	{
		path.color = glm::vec3(0.0f);
		path.remainingBounces = 0;	// terminate the ray because it is now useless
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, Intersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		Intersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
				pathSegments[idx].color *= u01(rng); // apply some noise because why not
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, int nIters, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];

		// I got rid of the division by iters in send to PBO and save Image
		// instead, I'm doing a lerp between all the previous iterations and the current iteration
		image[iterationPath.pixelIndex] = glm::mix(image[iterationPath.pixelIndex], iterationPath.color, 1.0f / nIters);
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (!iterationComplete) {
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;

#if CACHE_FIRST_INTERSECTION
		// are we caching the first intersection?
		// if we are, is this the FIRST bounce of a frame that is not the first frame?
		if (depth == 0 && iter > 1)
		{				
			// use the cached intersection
			cudaMemcpy(dev_intersections, dev_cached_intersections, pixelcount * sizeof(Intersection), cudaMemcpyDeviceToDevice);
		}
		else
#endif
		{
			// every other situation
			// use new intersections
			// this can be second bounces when caching
			// or first bounce of first frame when caching
			// or every single bounce when not caching

			// clean shading chunks
			cudaMemset(dev_intersections, 0, pixelcount * sizeof(Intersection));

			// tracing
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_tris
				, hst_scene->tris.size()
				, dev_bvhNodes
				, hst_scene->bvhNodes.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
			cudaDeviceSynchronize();
		}

#if CACHE_FIRST_INTERSECTION
		if (depth == 0 && iter == 1)
		{
			// if this is the first intersection of the first frame and caching is enabled
			// cache the first intersection
			cudaMemcpy(dev_cached_intersections, dev_intersections, pixelcount * sizeof(Intersection), cudaMemcpyDeviceToDevice);
		}
#endif

		depth++;

#if SORT_BY_MATERIAL
		// Sort intersections and paths by material Id
		// Theoretically this should make everything way faster
		// because now all arrays are contiguous based on material ID,
		// so all chunks of materials are processed together
		// However this is wrecking my scene FPS because - aha - the materials are not that complex
		// and sorting itself is super slow :)
		thrust::device_ptr<Intersection> thrust_dev_intersections(dev_intersections);
		thrust::stable_sort_by_key(thrust::device, thrust_dev_intersections, thrust_dev_intersections + num_paths, dev_paths, sortByMaterialId());
#endif

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	  // evaluating the BSDF.
	  // Start off with just a big kernel that handles all the different
	  // materials you have in the scenefile.

		kernel_sample_f<<<numblocksPathSegmentTracing, blockSize1d>>>(iter, depth,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials);

#if STREAM_COMPACT
		// compact away terminated paths
		// again, this should make unterminated paths on which threads are actually doing meaningful work contiguous
		// but similar to the material sorting, the gains achieved by doing that seem to be significantly outweighed
		// by the losses that come from the time partitioning the arrays takes
		// We can't use thrust::remove_if without doing fancy computations
		// because remove_if will move the "unterminated" arrays to the beginning of the array
		// but does not guarantee moving the "terminated" arrays to the end
		thrust::device_ptr<PathSegment> thrust_dev_paths(dev_paths);
		thrust::device_ptr<PathSegment> new_path_end = thrust::stable_partition(thrust::device, thrust_dev_paths, thrust_dev_paths + num_paths, notEquals(0));
		num_paths = new_path_end.get() - dev_paths;
#endif

		// we've either hit the max path tracing depth OR all paths have been terminated
		// stop tracing further
		iterationComplete = depth >= traceDepth || num_paths == 0;

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (pixelcount, iter, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
