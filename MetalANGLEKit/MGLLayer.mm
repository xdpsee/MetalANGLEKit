//
// Copyright 2019 Le Hoang Quyen. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import "MGLLayer+Private.h"

#include <vector>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <EGL/eglplatform.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl3.h>
#include <MetalANGLEKit/feature_support_util.h>
#import "MGLContext+Private.h"
#import "MGLDisplay.h"

namespace
{

constexpr GLchar kBlitVS[] = R"(
attribute vec2 aPosition;

varying mediump vec2 vTexcoords;

void main()
{
    gl_Position = vec4(aPosition.x, aPosition.y, 0.0, 1.0);
    vTexcoords = 0.5 * (aPosition + vec2(1.0, 1.0));
}
)";

constexpr GLchar kBlitFS[] = R"(
uniform sampler2D uTexture;

varying mediump vec2 vTexcoords;

void main()
{
    gl_FragColor = texture2D(uTexture, vTexcoords);
}
)";

template <GLenum State>
class ScopedGLEnable
{
  public:
    ScopedGLEnable(bool enable)
    {
        glGetIntegerv(State, &mPrevState);

        if (enable)
        {
            glEnable(State);
        }
        else
        {
            glDisable(State);
        }
    }
    ~ScopedGLEnable()
    {
        if (mPrevState)
        {
            glEnable(State);
        }
        else
        {
            glDisable(State);
        }
    }

  private:
    GLint mPrevState;
};

template <GLenum Target, GLenum TargetBindingGet, void (*BindFunc)(GLenum, GLuint)>
class ScopedGLBinding
{
  public:
    ScopedGLBinding(GLuint newObj)
    {
        glGetIntegerv(TargetBindingGet, &mPrevBoundObj);
        BindFunc(Target, newObj);
    }
    ~ScopedGLBinding() { BindFunc(Target, mPrevBoundObj); }

  private:
    GLint mPrevBoundObj;
};

using ScopedTextureBind = ScopedGLBinding<GL_TEXTURE_2D, GL_TEXTURE_BINDING_2D, glBindTexture>;
using ScopedBufferBind  = ScopedGLBinding<GL_ARRAY_BUFFER, GL_ARRAY_BUFFER_BINDING, glBindBuffer>;
using ScopedRenderbufferBind =
    ScopedGLBinding<GL_RENDERBUFFER, GL_RENDERBUFFER_BINDING, glBindRenderbuffer>;
using ScopedFBOBind = ScopedGLBinding<GL_FRAMEBUFFER, GL_FRAMEBUFFER_BINDING, glBindFramebuffer>;
using ScopedDrawFBOBind =
    ScopedGLBinding<GL_DRAW_FRAMEBUFFER, GL_FRAMEBUFFER_BINDING, glBindFramebuffer>;
using ScopedReadFBOBind =
    ScopedGLBinding<GL_READ_FRAMEBUFFER, GL_FRAMEBUFFER_BINDING, glBindFramebuffer>;

class ScopedProgramBind
{
  public:
    ScopedProgramBind(GLuint program)
    {
        glGetIntegerv(GL_CURRENT_PROGRAM, &mPrevProgram);
        glUseProgram(program);
    }
    ~ScopedProgramBind() { glUseProgram(mPrevProgram); }

  private:
    GLint mPrevProgram;
};

class ScopedActiveTexture
{
  public:
    ScopedActiveTexture(GLenum unit)
    {
        glGetIntegerv(GL_ACTIVE_TEXTURE, &mPrevActiveTexture);
        glActiveTexture(unit);
    }
    ~ScopedActiveTexture() { glActiveTexture(mPrevActiveTexture); }

  private:
    GLint mPrevActiveTexture;
};

struct ScopedVAOBind
{
  public:
    ScopedVAOBind(GLuint vao)
    {
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING_OES, &mPrevVAO);
        glBindVertexArrayOES(vao);
    }
    ~ScopedVAOBind() { glBindVertexArrayOES(mPrevVAO); }

  private:
    GLint mPrevVAO;
};

template <void (*DeleteFunc)(GLsizei, const GLuint *)>
class ScopedGLObject
{
  public:
    ScopedGLObject() : mObject(0) {}
    ScopedGLObject(GLuint object) : mObject(object) {}
    ~ScopedGLObject()
    {
        if (mObject)
        {
            DeleteFunc(1, &mObject);
        }
        mObject = 0;
    }

    ScopedGLObject &operator=(GLuint object)
    {
        mObject = object;
        return *this;
    }

    operator GLuint() const { return get(); }

    const GLuint &get() const { return mObject; }
    GLuint &get() { return mObject; }

  private:
    GLuint mObject;
};

using ScopedTexture      = ScopedGLObject<glDeleteTextures>;
using ScopedRenderbuffer = ScopedGLObject<glDeleteRenderbuffers>;
using ScopedFramebuffer  = ScopedGLObject<glDeleteFramebuffers>;

class ScopedViewport
{
  public:
    ScopedViewport(GLint x, GLint y, GLint width, GLint height)
    {
        glGetIntegerv(GL_VIEWPORT, mPrevViewport);
        glViewport(x, y, width, height);
    }
    ~ScopedViewport()
    {
        glViewport(mPrevViewport[0], mPrevViewport[1], mPrevViewport[2], mPrevViewport[3]);
    }

  private:
    GLint mPrevViewport[4];
};

class ScopedReadBuffer
{
  public:
    ScopedReadBuffer(GLint buffer, bool readBufferAvail) : mReadBufferAvail(readBufferAvail)
    {
        if (!mReadBufferAvail)
        {
            return;
        }
        glGetIntegerv(GL_READ_BUFFER, &mPrevReadBuffer);
        glReadBuffer(buffer);
    }
    ~ScopedReadBuffer()
    {
        if (mReadBufferAvail)
        {
            glReadBuffer(mPrevReadBuffer);
        }
    }

  private:
    const bool mReadBufferAvail;
    GLint mPrevReadBuffer;
};

class ScopedDrawBuffer
{
  public:
    ScopedDrawBuffer(GLenum drawbuffer, PFNGLDRAWBUFFERSEXTPROC drawBuffersFunc)
        : mDrawBuffersFunc(drawBuffersFunc)
    {
        if (!mDrawBuffersFunc)
        {
            return;
        }
        GLint maxDrawBuffers;
        glGetIntegerv(GL_MAX_DRAW_BUFFERS, &maxDrawBuffers);
        mPrevDrawBuffers.resize(maxDrawBuffers, GL_NONE);
        for (int i = 0; i < maxDrawBuffers; ++i)
        {
            GLint buffer = GL_NONE;
            glGetIntegerv(GL_DRAW_BUFFER0 + i, &buffer);
            mPrevDrawBuffers[i] = buffer;
        }
        mDrawBuffersFunc(1, &drawbuffer);
    }
    ~ScopedDrawBuffer()
    {
        if (!mDrawBuffersFunc)
        {
            return;
        }
        GLint currentFBO;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &currentFBO);
        if (currentFBO == 0)
        {
            mDrawBuffersFunc(1, mPrevDrawBuffers.data());
        }
        else
        {
            mDrawBuffersFunc(mPrevDrawBuffers.size(), mPrevDrawBuffers.data());
        }
    }

  private:
    std::vector<GLenum> mPrevDrawBuffers;
    const PFNGLDRAWBUFFERSEXTPROC mDrawBuffersFunc;
};

void Throw(NSString *msg)
{
    [NSException raise:@"MGLSurfaceException" format:@"%@", msg];
}

GLint CompileShader(GLenum target, const GLchar *source, GLuint *shader)
{
    GLint logLength, status;

    *shader                 = glCreateShader(target);
    const GLchar *sources[] = {source};
    glShaderSource(*shader, 1, sources, NULL);
    glCompileShader(*shader);
    glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(*shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }

    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == GL_FALSE)
    {
        NSLog(@"Failed to compile shader:\n");
        NSLog(@"%s", source);
    }

    return status && *shader;
}

GLint LinkProgram(GLuint program)
{
    GLint logLength, status;

    glLinkProgram(program);
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(program, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }

    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status == 0)
        NSLog(@"Failed to link program %d", program);

    return status && program;
}
}

// MGLLayer implementation
@implementation MGLLayer

- (id)init
{
    if (self = [super init])
    {
        [self constructor];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    if (self = [super initWithCoder:coder])
    {
        [self constructor];
    }
    return self;
}

- (void)constructor
{
    _drawableColorFormat   = MGLDrawableColorFormatRGBA8888;
    _drawableDepthFormat   = MGLDrawableDepthFormatNone;
    _drawableStencilFormat = MGLDrawableStencilFormatNone;
    _drawableMultisample   = MGLDrawableMultisampleNone;

    _display = [MGLDisplay defaultDisplay];

    _eglSurface = EGL_NO_SURFACE;

    if (ANGLEIsMetalRendererAvailable())
    {
        _metalLayer       = [[CAMetalLayer alloc] init];
        _metalLayer.frame = self.bounds;
        [self addSublayer:_metalLayer];
    }
    else
    {
        _legacyGLLayer       = [[CALayer alloc] init];
        _legacyGLLayer.frame = self.bounds;
        [self addSublayer:_legacyGLLayer];
    }
}

- (void)dealloc
{
    [self releaseSurface];

    _display = nil;
}

- (void)setContentsScale:(CGFloat)contentsScale
{
    [super setContentsScale:contentsScale];

    if (ANGLEIsMetalRendererAvailable())
    {
        _metalLayer.contentsScale = contentsScale;
    }
    else
    {
        _legacyGLLayer.contentsScale = contentsScale;
    }
}

- (CGSize)drawableSize
{
    if (ANGLEIsMetalRendererAvailable())
    {
        if (_metalLayer.drawableSize.width == 0 && _metalLayer.drawableSize.height == 0)
        {
            [self checkLayerSize];
        }
        return _metalLayer.drawableSize;
    }

    return CGSizeMake(self.bounds.size.width * self.contentsScale,
                      self.bounds.size.height * self.contentsScale);
}

- (BOOL)setCurrentContext:(MGLContext *)context
{
    if (eglGetCurrentContext() != context.eglContext ||
        eglGetCurrentSurface(EGL_READ) != self.eglSurface ||
        eglGetCurrentSurface(EGL_DRAW) != self.eglSurface)
    {
        if (!eglMakeCurrent(_display.eglDisplay, self.eglSurface, self.eglSurface,
                            context.eglContext))
        {
            return NO;
        }
    }

    if (_useOffscreenFBO)
    {
        GLint currentFBO;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &currentFBO);
        BOOL offscreenFBOWasBound = currentFBO == _defaultOpenGLFrameBufferID;

        if (![self ensureOffscreenFBOCreated])
        {
            return NO;
        }

        if (offscreenFBOWasBound)
        {
            // Draw to offscreen texture instead of eglSurface
            glBindFramebuffer(GL_FRAMEBUFFER, _defaultOpenGLFrameBufferID);
        }
    }

    return YES;
}

- (void)bindDefaultFrameBuffer
{
    glBindFramebuffer(GL_FRAMEBUFFER, _defaultOpenGLFrameBufferID);
}

- (BOOL)present
{
    if (_useOffscreenFBO)
    {
        if (_blitFramebufferAvail)
        {
            if (![self blitFBO:_defaultOpenGLFrameBufferID
                         sourceSize:_offscreenFBOSize
                              toFBO:0
                    destinationSize:self.drawableSize
                    destinationMSAA:NO])
            {
                return NO;
            }
        }
        else if (![self blitOffscreenTexture:_offscreenTexture toFBO:0])
        {
            return NO;
        }
    }

    if (!eglSwapBuffers(_display.eglDisplay, self.eglSurface))
    {
        return NO;
    }

    [self checkLayerSize];

    return YES;
}

- (BOOL)blitFBO:(GLuint)srcFbo
         sourceSize:(CGSize)srcSize
              toFBO:(GLuint)dstFbo
    destinationSize:(CGSize)dstSize
    destinationMSAA:(BOOL)destinationMSAA
{
    if (srcSize.width != dstSize.width || srcSize.height != dstSize.height || destinationMSAA)
    {
        // Blit to a temporary texture
        ScopedTexture tempTexture;
        glGenTextures(1, &tempTexture.get());
        ScopedTextureBind bindTexture(tempTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexImage2D(GL_TEXTURE_2D, 0, _offscreenColorUnsizedFormat,
                       static_cast<GLint>(srcSize.width), static_cast<GLint>(srcSize.height), 0,
                       _offscreenColorUnsizedFormat, _offscreenColorFormatDataType, 0);

        ScopedFramebuffer tempFBO;
        glGenFramebuffers(1, &tempFBO.get());
        ScopedFBOBind bindFBO(tempFBO);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tempTexture,
                                 0);

        if (![self blitFBO:srcFbo
                     sourceSize:srcSize
                          toFBO:tempFBO
                destinationSize:srcSize
                destinationMSAA:NO])
        {
            return NO;
        }

        // Draw the temporary texture to destination framebuffer
        return [self blitOffscreenTexture:tempTexture toFBO:dstFbo];
    }

    // Same size blitting
    assert(_blitFramebufferAvail);
    auto currentCtx   = [MGLContext currentContext];
    auto currentLayer = [MGLContext currentLayer];
    [MGLContext setCurrentContext:_offscreenFBOCreatorContext forLayer:self];

    ScopedDrawFBOBind bindDrawFBO(dstFbo);
    ScopedReadFBOBind bindReadFBO(srcFbo);
    ScopedReadBuffer setReadBuffer(GL_COLOR_ATTACHMENT0, _isGLES3Plus);
    ScopedDrawBuffer setDrawBuffer(dstFbo ? GL_COLOR_ATTACHMENT0 : GL_BACK,
                                   _isGLES3Plus ? glDrawBuffers : glDrawBuffersEXT);
    ScopedGLEnable<GL_SCISSOR_TEST> disableScissorTest(false);

    auto blitFunc = _isGLES3Plus ? glBlitFramebuffer : glBlitFramebufferANGLE;

    blitFunc(0, 0, static_cast<GLint>(srcSize.width), static_cast<GLint>(srcSize.height), 0, 0,
             static_cast<GLint>(dstSize.width), static_cast<GLint>(dstSize.height),
             GL_COLOR_BUFFER_BIT, GL_NEAREST);

    BOOL re = glGetError() == GL_NO_ERROR;

    [MGLContext setCurrentContext:currentCtx forLayer:currentLayer];

    return re;
}

- (BOOL)blitOffscreenTexture:(GLuint)texture toFBO:(GLuint)fbo
{
    assert(texture && _offscreenBlitProgram && _offscreenBlitVAO);

    auto currentCtx   = [MGLContext currentContext];
    auto currentLayer = [MGLContext currentLayer];
    [MGLContext setCurrentContext:_offscreenFBOCreatorContext forLayer:self];

    ScopedFBOBind bindFBO(fbo);
    ScopedDrawBuffer setDrawBuffer(fbo ? GL_COLOR_ATTACHMENT0 : GL_BACK,
                                   _isGLES3Plus ? glDrawBuffers : glDrawBuffersEXT);
    ScopedProgramBind bindProgram(_offscreenBlitProgram);
    ScopedActiveTexture activeTexture(GL_TEXTURE0);
    ScopedTextureBind bindTexture(texture);
    ScopedVAOBind bindVAO(_offscreenBlitVAO);

    ScopedGLEnable<GL_CULL_FACE> disableCull(false);
    ScopedGLEnable<GL_DEPTH_TEST> disableDepthTest(false);
    ScopedGLEnable<GL_STENCIL_TEST> disableStencilTest(false);
    ScopedGLEnable<GL_BLEND> disableBlend(false);
    ScopedGLEnable<GL_SCISSOR_TEST> disableScissorTest(false);

    ScopedViewport setViewport(0, 0, static_cast<GLint>(_offscreenFBOSize.width),
                               static_cast<GLint>(_offscreenFBOSize.height));

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    BOOL re = glGetError() == GL_NO_ERROR;

    [MGLContext setCurrentContext:currentCtx forLayer:currentLayer];

    return re;
}

- (EGLSurface)eglSurface
{
    [self ensureSurfaceCreated];

    return _eglSurface;
}

- (void)setDrawableColorFormat:(MGLDrawableColorFormat)drawableColorFormat
{
    _drawableColorFormat = drawableColorFormat;
    [self releaseSurface];
}

- (void)setDrawableDepthFormat:(MGLDrawableDepthFormat)drawableDepthFormat
{
    _drawableDepthFormat = drawableDepthFormat;
    [self releaseSurface];
}

- (void)setDrawableStencilFormat:(MGLDrawableStencilFormat)drawableStencilFormat
{
    _drawableStencilFormat = drawableStencilFormat;
    [self releaseSurface];
}

- (void)setDrawableMultisample:(MGLDrawableMultisample)drawableMultisample
{
    _drawableMultisample = drawableMultisample;
    if (!ANGLEIsMetalRendererAvailable() && _drawableMultisample > 0)
    {
        // Default backbuffer MSAA is not supported in native GL backend yet.
        // Use offscreen MSAA buffer.
        _useOffscreenFBO = YES;
    }
    [self releaseSurface];
}

- (void)setRetainedBacking:(BOOL)retainedBacking
{
    if (!ANGLEIsMetalRendererAvailable())
    {
        if (_drawableMultisample > 0)
        {
            // Default backbuffer MSAA is not supported in native GL backend yet.
            // Always use offscreen MSAA buffer.
            _useOffscreenFBO = YES;
        }
        else
        {
            _useOffscreenFBO = retainedBacking;
        }
    }
    // else Metal back-end already supports preserve swap behavior.
    _retainedBacking = retainedBacking;
}

- (void)releaseSurface
{
    if (_eglSurface == eglGetCurrentSurface(EGL_READ) ||
        _eglSurface == eglGetCurrentSurface(EGL_DRAW))
    {
        eglMakeCurrent(_display.eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (_eglSurface != EGL_NO_SURFACE)
    {
        eglDestroySurface(_display.eglDisplay, _eglSurface);
        _eglSurface = EGL_NO_SURFACE;
    }
    [self releaseOffscreenRenderingResources];
}

- (void)releaseOffscreenRenderingResources
{
    if (_defaultOpenGLFrameBufferID)
    {
        auto oldUseOffscreenFBOFlag = _useOffscreenFBO;
        // Avoid the buffer being created again inside setCurrentContext:
        _useOffscreenFBO  = NO;
        auto currentCtx   = [MGLContext currentContext];
        auto currentLayer = [MGLContext currentLayer];
        [MGLContext setCurrentContext:_offscreenFBOCreatorContext];

        glDeleteFramebuffers(1, &_defaultOpenGLFrameBufferID);
        _defaultOpenGLFrameBufferID = 0;

        glDeleteTextures(1, &_offscreenTexture);
        _offscreenTexture = 0;
        glDeleteRenderbuffers(1, &_offscreenRenderBuffer);
        _offscreenRenderBuffer = 0;
        glDeleteRenderbuffers(1, &_offscreenDepthStencilBuffer);
        _offscreenDepthStencilBuffer = 0;
        glDeleteVertexArraysOES(1, &_offscreenBlitVAO);
        _offscreenBlitVAO = 0;
        glDeleteBuffers(1, &_offscreenBlitVBO);
        _offscreenBlitVBO = 0;
        glDeleteBuffers(1, &_offscreenBlitProgram);
        _offscreenBlitProgram = 0;

        [MGLContext setCurrentContext:currentCtx forLayer:currentLayer];

        _useOffscreenFBO = oldUseOffscreenFBOFlag;
    }

    _offscreenFBOSize.width = _offscreenFBOSize.height = 0;
}

- (void)checkLayerSize
{
    if (ANGLEIsMetalRendererAvailable())
    {
        // Resize the metal layer
        [CATransaction begin];
        [CATransaction setValue:(id)kCFBooleanTrue
                         forKey:kCATransactionDisableActions];
        _metalLayer.frame = self.bounds;
        _metalLayer.drawableSize =
            CGSizeMake(_metalLayer.bounds.size.width * _metalLayer.contentsScale,
                       _metalLayer.bounds.size.height * _metalLayer.contentsScale);
        [CATransaction commit];
    }
    else
    {
        _legacyGLLayer.frame = self.bounds;
    }
}

- (void)ensureSurfaceCreated
{
    if (_eglSurface != EGL_NO_SURFACE)
    {
        return;
    }

    [self checkLayerSize];

    int red = 8, green = 8, blue = 8, alpha = 8;
    int colorSpace;
    switch (_drawableColorFormat)
    {
        case MGLDrawableColorFormatRGBA8888:
        // RGB565 default framebuffer is not supported by Metal atm.
        // Fallback to RGBA8.
        case MGLDrawableColorFormatRGB565:
            red = green = blue = alpha = 8;
            colorSpace                 = EGL_GL_COLORSPACE_LINEAR_KHR;
            break;
        case MGLDrawableColorFormatSRGBA8888:
            red = green = blue = alpha = 8;
            colorSpace                 = EGL_GL_COLORSPACE_SRGB_KHR;
            break;
        default:
            abort();
            break;
    }

    // Init surface
    std::vector<EGLint> surfaceAttribs = {
        EGL_RED_SIZE,       red,
        EGL_GREEN_SIZE,     green,
        EGL_BLUE_SIZE,      blue,
        EGL_ALPHA_SIZE,     alpha,
        EGL_DEPTH_SIZE,     _useOffscreenFBO ? 0 : _drawableDepthFormat,
        EGL_STENCIL_SIZE,   _useOffscreenFBO ? 0 : _drawableStencilFormat,
        EGL_SAMPLE_BUFFERS, 0,
        EGL_SAMPLES,        _useOffscreenFBO ? EGL_DONT_CARE : _drawableMultisample,
    };
    surfaceAttribs.push_back(EGL_NONE);
    EGLConfig config;
    EGLint numConfigs;
    if (!eglChooseConfig(_display.eglDisplay, surfaceAttribs.data(), &config, 1, &numConfigs) ||
        numConfigs < 1)
    {
        Throw(@"Failed to call eglChooseConfig()");
    }

    EGLint creationAttribs[] = {EGL_GL_COLORSPACE_KHR, colorSpace, EGL_NONE};

    EGLNativeWindowType nativeWindowPtr;

    if (ANGLEIsMetalRendererAvailable())
    {
        // If metal layer is available, use it directly
        nativeWindowPtr = (__bridge EGLNativeWindowType)_metalLayer;
    }
    else
    {
        nativeWindowPtr = (__bridge EGLNativeWindowType)_legacyGLLayer;
    }

    _eglSurface =
        eglCreateWindowSurface(_display.eglDisplay, config, nativeWindowPtr, creationAttribs);
    if (_eglSurface == EGL_NO_SURFACE)
    {
        Throw(@"Failed to call eglCreateWindowSurface()");
    }

    if (_retainedBacking && !_useOffscreenFBO)
    {
        eglSurfaceAttrib(_display.eglDisplay, _eglSurface, EGL_SWAP_BEHAVIOR, EGL_BUFFER_PRESERVED);
    }
}

- (BOOL)ensureOffscreenFBOCreated
{
    assert(eglGetCurrentContext() != EGL_NO_CONTEXT);

    ScopedTexture oldOffscreenTexture           = 0;
    ScopedRenderbuffer oldOffscreenRenderbuffer = 0;
    CGSize oldOffscreenSize                     = _offscreenFBOSize;

    if (_offscreenFBOCreatorContext != [MGLContext currentContext] || !
                                                                      [self verifyOffscreenFBOSize])
    {
        // We need to copy the old texture to current texture, so backup the offscreen
        // texture/buffer value and set those instance variables to zero to avoid the texture/buffer
        // being released.
        oldOffscreenTexture      = _offscreenTexture;
        oldOffscreenRenderbuffer = _offscreenRenderBuffer;
        oldOffscreenSize         = _offscreenFBOSize;
        _offscreenTexture        = 0;
        _offscreenRenderBuffer   = 0;
        [self releaseOffscreenRenderingResources];
    }

    if (_defaultOpenGLFrameBufferID)
    {
        // Already created.
        return YES;
    }

    if (![self createOffscreenRenderingResources])
    {
        [self releaseOffscreenRenderingResources];
        return NO;
    }

    // Copy old content to new offscreen framebuffer
    if (oldOffscreenTexture.get() || oldOffscreenRenderbuffer.get())
    {
        if (_blitFramebufferAvail)
        {
            ScopedFramebuffer tempFBO;
            glGenFramebuffers(1, &tempFBO.get());
            glBindFramebuffer(GL_READ_FRAMEBUFFER, tempFBO);
            glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER,
                                        oldOffscreenRenderbuffer);

            return [self blitFBO:tempFBO
                      sourceSize:oldOffscreenSize
                           toFBO:_defaultOpenGLFrameBufferID
                 destinationSize:_offscreenFBOSize
                 destinationMSAA:_drawableMultisample];
        }
        return [self blitOffscreenTexture:oldOffscreenTexture toFBO:_defaultOpenGLFrameBufferID];
    }

    return YES;
}

- (BOOL)createOffscreenRenderingResources
{
    auto version          = reinterpret_cast<const char *>(glGetString(GL_VERSION));
    auto exts             = reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS));
    _isGLES3Plus          = strstr(version, "OpenGL ES 3") != nullptr;
    _drawBuffersAvail     = _isGLES3Plus || strstr(exts, "GL_EXT_draw_buffers") != nullptr;
    _blitFramebufferAvail = _isGLES3Plus || strstr(exts, "GL_ANGLE_framebuffer_blit") != nullptr;

    if (![self createOffscreenBlitVBO])
    {
        return NO;
    }

    if (![self createOffscreenBlitProgram])
    {
        return NO;
    }

    return [self createOffscreenFBO];
}

- (BOOL)createOffscreenFBO
{
    // Clear pending errors
    glGetError();

    _offscreenFBOCreatorContext = [MGLContext currentContext];
    _offscreenFBOSize           = self.drawableSize;

    glGenFramebuffers(1, &_defaultOpenGLFrameBufferID);

    ScopedFBOBind bindFBO(_defaultOpenGLFrameBufferID);

    if (_blitFramebufferAvail)
    {
        if (![self createOffscreenRenderBuffer])
        {
            return NO;
        }
    }
    else
    {
        if (![self createOffscreenTexture])
        {
            return NO;
        }
    }

    if (![self createOffscreenDepthStencilbuffer])
    {
        return NO;
    }

    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
    {
        // Fatal error
        Throw(@"Offscreen texture is not complete");
    }

    return _defaultOpenGLFrameBufferID && glGetError() == GL_NO_ERROR;
}

- (BOOL)createOffscreenDepthStencilbuffer
{
    // Clear pending errors
    glGetError();

    int depthBits   = _drawableDepthFormat;
    int stencilBits = _drawableStencilFormat;

    if (!depthBits && !stencilBits)
    {
        // No depth & stencil buffer
        return YES;
    }

    GLenum depthStencilFormat = 0;
    if (depthBits && stencilBits)
    {
        depthStencilFormat = GL_DEPTH24_STENCIL8_OES;
    }
    else if (depthBits)
    {
        depthStencilFormat = GL_DEPTH_COMPONENT24_OES;
    }
    else if (stencilBits)
    {
        depthStencilFormat = GL_STENCIL_INDEX8;
    }

    glGenRenderbuffers(1, &_offscreenDepthStencilBuffer);
    ScopedRenderbufferBind bindRenderbuffer(_offscreenDepthStencilBuffer);

    if (_drawableMultisample)
    {
        glRenderbufferStorageMultisampleANGLE(GL_RENDERBUFFER, _drawableMultisample,
                                                depthStencilFormat,
                                                static_cast<GLsizei>(_offscreenFBOSize.width),
                                                static_cast<GLsizei>(_offscreenFBOSize.height));
    }
    else
    {
        glRenderbufferStorage(GL_RENDERBUFFER, depthStencilFormat,
                                static_cast<GLsizei>(_offscreenFBOSize.width),
                                static_cast<GLsizei>(_offscreenFBOSize.height));
    }

    if (depthBits)
    {
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
                                    _offscreenDepthStencilBuffer);
    }
    if (stencilBits)
    {
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                                    _offscreenDepthStencilBuffer);
    }

    return _offscreenDepthStencilBuffer && glGetError() == GL_NO_ERROR;
}

// Offscreen renderbuffer is used when glBlitFramebuffer is available.
- (BOOL)createOffscreenRenderBuffer
{
    assert(_blitFramebufferAvail);

    // Clear pending errors
    glGetError();

    GLenum sizedFormat;
    switch (_drawableColorFormat)
    {
        case MGLDrawableColorFormatRGBA8888:
        case MGLDrawableColorFormatRGB565:
            sizedFormat                   = GL_RGBA8_OES;
            _offscreenColorUnsizedFormat  = GL_RGBA;
            _offscreenColorFormatDataType = GL_UNSIGNED_BYTE;
            break;
        case MGLDrawableColorFormatSRGBA8888:
            sizedFormat                   = GL_SRGB8_ALPHA8_EXT;
            _offscreenColorUnsizedFormat  = GL_SRGB_ALPHA_EXT;
            _offscreenColorFormatDataType = GL_UNSIGNED_BYTE;
            break;
        default:
            abort();
            break;
    }

    glGenRenderbuffers(1, &_offscreenRenderBuffer);
    ScopedRenderbufferBind bindRenderbuffer(_offscreenRenderBuffer);

    if (_drawableMultisample)
    {
        glRenderbufferStorageMultisampleANGLE(GL_RENDERBUFFER, _drawableMultisample, sizedFormat,
                                                static_cast<GLsizei>(_offscreenFBOSize.width),
                                                static_cast<GLsizei>(_offscreenFBOSize.height));
    }
    else
    {
        glRenderbufferStorage(GL_RENDERBUFFER, sizedFormat,
                                static_cast<GLsizei>(_offscreenFBOSize.width),
                                static_cast<GLsizei>(_offscreenFBOSize.height));
    }

    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER,
                                _offscreenRenderBuffer);

    return _offscreenRenderBuffer && glGetError() == GL_NO_ERROR;
}

// Offscreen texture is used when glBlitFramebuffer is NOT available.
- (BOOL)createOffscreenTexture
{
    assert(!_blitFramebufferAvail);

    // Clear pending errors
    glGetError();

    glGenTextures(1, &_offscreenTexture);

    ScopedTextureBind bindTexture(_offscreenTexture);

    GLenum textureSizedFormat;
    GLenum textureFormat;
    GLenum type;
    switch (_drawableColorFormat)
    {
        case MGLDrawableColorFormatRGBA8888:
        case MGLDrawableColorFormatRGB565:
            textureSizedFormat = GL_RGBA8_OES;
            textureFormat      = GL_RGBA;
            type               = GL_UNSIGNED_BYTE;
        case MGLDrawableColorFormatSRGBA8888:
            textureSizedFormat = GL_SRGB8_ALPHA8_EXT;
            textureFormat      = GL_SRGB_ALPHA_EXT;
            type               = GL_UNSIGNED_BYTE;
            break;
        default:
            abort();
            break;
    }

    _offscreenColorUnsizedFormat  = textureFormat;
    _offscreenColorFormatDataType = type;

    if (ANGLEIsMetalRendererAvailable())
    {
        glTexStorage2DEXT(GL_TEXTURE_2D, 1, textureSizedFormat,
                            static_cast<GLsizei>(_offscreenFBOSize.width),
                            static_cast<GLsizei>(_offscreenFBOSize.height));
    }
    else
    {
        glTexImage2D(
            GL_TEXTURE_2D, 0, textureFormat, static_cast<GLsizei>(_offscreenFBOSize.width),
            static_cast<GLsizei>(_offscreenFBOSize.height), 0, textureFormat, type, nullptr);
    }

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    if (_drawableMultisample)
    {
        glFramebufferTexture2DMultisampleEXT(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                                               _offscreenTexture, 0, _drawableMultisample);
    }
    else
    {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                                 _offscreenTexture, 0);
    }

    return _offscreenTexture && glGetError() == GL_NO_ERROR;
}

- (BOOL)verifyOffscreenFBOSize
{
    if (!_defaultOpenGLFrameBufferID)
    {
        return YES;
    }

    return static_cast<NSUInteger>(_offscreenFBOSize.width) ==
               static_cast<NSUInteger>(self.drawableSize.width) &&
           static_cast<NSUInteger>(_offscreenFBOSize.height) ==
               static_cast<NSUInteger>(self.drawableSize.height);
}

- (BOOL)createOffscreenBlitProgram
{
    GLenum vshader, fshader;
    if (!CompileShader(GL_VERTEX_SHADER, kBlitVS, &vshader))
    {
        return NO;
    }

    if (!CompileShader(GL_FRAGMENT_SHADER, kBlitFS, &fshader))
    {
        return NO;
    }

    _offscreenBlitProgram = glCreateProgram();
    glAttachShader(_offscreenBlitProgram, vshader);
    glAttachShader(_offscreenBlitProgram, fshader);
    glBindAttribLocation(_offscreenBlitProgram, 0, "aPosition");

    if (!LinkProgram(_offscreenBlitProgram))
    {
        return NO;
    }
    GLint textureLocation = -1;
    textureLocation       = glGetUniformLocation(_offscreenBlitProgram, "uTexture");
    assert(textureLocation != -1);

    ScopedProgramBind bindProgram(_offscreenBlitProgram);
    glUniform1i(textureLocation, 0);

    return YES;
}

- (BOOL)createOffscreenBlitVBO
{
    // Clear pending errors
    glGetError();

    constexpr float kBlitVertices[] = {-1, 1, -1, -1, 1, 1, 1, -1};

    glGenVertexArraysOES(1, &_offscreenBlitVAO);
    glGenBuffers(1, &_offscreenBlitVBO);
    ScopedVAOBind bindVAO(_offscreenBlitVAO);
    ScopedBufferBind bindVBO(_offscreenBlitVBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kBlitVertices), kBlitVertices, GL_STATIC_DRAW);

    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);

    return _offscreenBlitVAO && _offscreenBlitVBO && glGetError() == GL_NO_ERROR;
}

@end
