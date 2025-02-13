#pragma once

#include "glm/glm.hpp"
#include <algorithm>
#include <istream>
#include <ostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

#define PI                3.1415926535897932384626422832795028841971f
#define TWO_PI            6.2831853071795864769252867665590057683943f
#define PI_OVER_2         1.57079632679489661923f
#define PI_OVER_4         0.78539816339744830961f 
#define SQRT_OF_ONE_THIRD 0.5773502691896257645091487805019574556476f
#define EPSILON           0.00001f

// Easing how much I have to write when using unique pointers
#define uPtr std::unique_ptr
#define mkU std::make_unique
#define X_AXIS 0
#define Y_AXIS 1
#define Z_AXIS 2

#define SORT_BY_MATERIAL 0
#define STREAM_COMPACT 0
#define CACHE_FIRST_INTERSECTION 0
#define ENABLE_NAIVE_AABB_OPTIMISATION 1
#define ENABLE_BVH 1
#define ENABLE_RUSSIAN_ROULETTE 1
#define ENABLE_HDR_GAMMA_CORRECTION 0

#define GAMMA 2.2

#define DEBUG 1

class GuiDataContainer
{
public:
    GuiDataContainer() : TracedDepth(0) {}
    int TracedDepth;
};

namespace utilityCore {
    extern float clamp(float f, float min, float max);
    extern bool replaceString(std::string& str, const std::string& from, const std::string& to);
    extern glm::vec3 clampRGB(glm::vec3 color);
    extern bool epsilonCheck(float a, float b);
    extern std::vector<std::string> tokenizeString(std::string str);
    extern glm::mat4 buildTransformationMatrix(glm::vec3 translation, glm::vec3 rotation, glm::vec3 scale);
    extern std::string convertIntToString(int number);
    extern std::istream& safeGetline(std::istream& is, std::string& t); //Thanks to http://stackoverflow.com/a/6089413
}