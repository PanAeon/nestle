#pragma parameter WHATEVER "Whatever" 0.0 0.0 1.0 1.0

#if defined(VERTEX)

#if __VERSION__ >= 130
#define COMPAT_VARYING out
#define COMPAT_ATTRIBUTE in
#define COMPAT_TEXTURE texture
#else
#define COMPAT_VARYING varying 
#define COMPAT_ATTRIBUTE attribute 
#define COMPAT_TEXTURE texture2D
#endif

#ifdef GL_ES
#define COMPAT_PRECISION mediump
#else
#define COMPAT_PRECISION
#endif

COMPAT_ATTRIBUTE vec4 VertexCoord;
COMPAT_ATTRIBUTE vec4 TexCoord;
COMPAT_VARYING vec4 TEX0;
// out variables go here as COMPAT_VARYING whatever

uniform mat4 MVPMatrix;
uniform COMPAT_PRECISION int FrameDirection;
uniform COMPAT_PRECISION int FrameCount;
uniform COMPAT_PRECISION vec2 OutputSize;
uniform COMPAT_PRECISION vec2 TextureSize;
uniform COMPAT_PRECISION vec2 InputSize;

// compatibility #defines
#define vTexCoord TEX0.xy
#define SourceSize vec4(TextureSize, 1.0 / TextureSize) //either TextureSize or InputSize
#define OutSize vec4(OutputSize, 1.0 / OutputSize)

#ifdef PARAMETER_UNIFORM
uniform COMPAT_PRECISION float WHATEVER;
#else
#define WHATEVER 0.0
#endif

void main()
{
   gl_Position = MVPMatrix * VertexCoord;
   TEX0.xy = TexCoord.xy;
}

#elif defined(FRAGMENT)

#ifdef GL_ES
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#define COMPAT_PRECISION mediump
#else
#define COMPAT_PRECISION
#endif

#if __VERSION__ >= 130
#define COMPAT_VARYING in
#define COMPAT_TEXTURE texture
out COMPAT_PRECISION vec4 FragColor;
#else
#define COMPAT_VARYING varying
#define FragColor gl_FragColor
#define COMPAT_TEXTURE texture2D
#endif

uniform COMPAT_PRECISION int FrameDirection;
uniform COMPAT_PRECISION int FrameCount;
uniform COMPAT_PRECISION vec2 OutputSize;
uniform COMPAT_PRECISION vec2 TextureSize;
uniform COMPAT_PRECISION vec2 InputSize;
uniform sampler2D Texture;
COMPAT_VARYING vec4 TEX0;
// in variables go here as COMPAT_VARYING whatever

// compatibility #defines
#define Source Texture
#define vTexCoord TEX0.xy

#define SourceSize vec4(TextureSize, 1.0 / TextureSize) //either TextureSize or InputSize
#define OutSize vec4(OutputSize, 1.0 / OutputSize)

// delete all 'params.' or 'registers.' or whatever in the fragment and replace
// texture(a, b) with COMPAT_TEXTURE(a, b) <-can't macro unfortunately

#ifdef PARAMETER_UNIFORM
uniform COMPAT_PRECISION float WHATEVER;
uniform COMPAT_PRECISION float scanlineIntensity;
uniform COMPAT_PRECISION float scanlineCount;
uniform COMPAT_PRECISION float yOffset;
uniform COMPAT_PRECISION float brightness;
uniform COMPAT_PRECISION float contrast;
uniform COMPAT_PRECISION float saturation;
uniform COMPAT_PRECISION float bloomIntensity;
uniform COMPAT_PRECISION float bloomThreshold;
uniform COMPAT_PRECISION float rgbShift;
uniform COMPAT_PRECISION float adaptiveIntensity;
uniform COMPAT_PRECISION float vignetteStrength;
uniform COMPAT_PRECISION float curvature;
uniform COMPAT_PRECISION float flickerStrength;
#else
#define WHATEVER 0.0
#define scanlineIntensity 0.15
#define scanlineCount 240.0
#define yOffset 0.0
#define brightness 1.1
#define contrast 1.05
#define saturation 1.1
#define bloomIntensity 0.2
#define bloomThreshold 0.5
#define rgbShift 0.0
#define adaptiveIntensity 0.5
#define vignetteStrength 0.3
#define curvature 0.15
#define flickerStrength 0.01
#endif



// Optimized curvature function
vec2 curveRemapUV(vec2 uv, float _curvature) {
  vec2 coords = uv * 2.0 - 1.0;
  float curveAmount = _curvature * 0.25; // Reduced from 0.5
  float dist = dot(coords, coords); // More efficient than x*x + y*y
  coords = coords * (1.0 + dist * curveAmount);
  return coords * 0.5 + 0.5;
}

// Optimized bloom sampling (2x2 instead of 3x3)
vec4 sampleBloom(sampler2D tex, vec2 uv, float radius) {
  vec4 bloom = COMPAT_TEXTURE(tex, uv) * 0.4;
  bloom += COMPAT_TEXTURE(tex, uv + vec2(radius, 0.0)) * 0.2;
  bloom += COMPAT_TEXTURE(tex, uv + vec2(-radius, 0.0)) * 0.2;
  bloom += COMPAT_TEXTURE(tex, uv + vec2(0.0, radius)) * 0.2;
  return bloom;
}

// Approximates vignette using Chebyshev distance squared instead of pow()
float vignetteApprox(vec2 uv, float strength) {
  vec2 vigCoord = uv * 2.0 - 1.0;
  float dist = max(abs(vigCoord.x), abs(vigCoord.y));
  return 1.0 - dist * dist * strength; // Use squared distance instead of pow
}

void main() {
  vec2 uv = vTexCoord;

  // Apply screen curvature if enabled
  if (curvature > 0.0) {
    uv = curveRemapUV(uv, curvature);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
      FragColor = vec4(0.0);
      return;
    }
  }

  // Get the original pixel color
  vec4 pixel = COMPAT_TEXTURE(Texture, uv);

  // Apply bloom effect with threshold-based sampling
  if (bloomIntensity > 0.0) {
    float pixelLum = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));
    // Only sample bloom if pixel is above threshold
    if (pixelLum > bloomThreshold * 0.5) {
      vec4 bloomSample = sampleBloom(Texture, uv, 0.005);
      bloomSample.rgb *= brightness;
      float bloomLum = dot(bloomSample.rgb, vec3(0.299, 0.587, 0.114));
      float bloomFactor = bloomIntensity * max(0.0, (bloomLum - bloomThreshold) * 1.5);
      pixel.rgb += bloomSample.rgb * bloomFactor;
    }
  }

  // Apply RGB shift only if needed
  if (rgbShift > 0.001) {
    float shift = rgbShift * 0.005; // Reduced offset
    pixel.r += COMPAT_TEXTURE(Texture, vec2(uv.x + shift, uv.y)).r * 0.08;
    pixel.b += COMPAT_TEXTURE(Texture, vec2(uv.x - shift, uv.y)).b * 0.08;
  }

  // Apply brightness
  pixel.rgb *= brightness;

  // Apply contrast
  pixel.rgb = (pixel.rgb - 0.5) * contrast + 0.5;

  // Apply saturation adjustment
  float luminance = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));
  pixel.rgb = mix(vec3(luminance), pixel.rgb, saturation);

  // Calculate scanlines with caching
  float scanline = 1.0;
  if (scanlineIntensity > 0.0) {
    float scanlineY = (uv.y + yOffset) * scanlineCount;
    // Use built-in sin directly without pi constant
    float scanlinePattern = abs(sin(scanlineY * 3.14159265));
    float adaptiveFactor = 1.0;
    if (adaptiveIntensity > 0.001) {
      float yPattern = sin(uv.y * 30.0) * 0.5 + 0.5;
      adaptiveFactor = 1.0 - yPattern * adaptiveIntensity * 0.2;
    }
    scanline = 1.0 - scanlinePattern * scanlineIntensity * adaptiveFactor;
  }

  // Apply flicker effect
  float flicker = 1.0 + sin(FrameCount * 110.0) * flickerStrength;

  // Apply optimized vignette
  float vignette = 1.0;
  if (vignetteStrength > 0.0) {
    vignette = vignetteApprox(uv, vignetteStrength);
  }

  // Apply combined lighting effects
  pixel.rgb *= scanline * flicker * vignette;

  FragColor = pixel;
}
// void main()
// {
// // Paste fragment contents here:
//
    // FragColor = COMPAT_TEXTURE(Source, vTexCoord);
// } 
#endif

