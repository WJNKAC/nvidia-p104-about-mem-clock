/* clburn.c —— 纯计算负载（不创建 GL 上下文、不碰显示路径）
 *
 * 目的（报告 213）：判断"把 MEM 打成 405"的破坏点是在
 *   (a) GL / 显示路径，还是
 *   (b) 通用 P-State 评估
 *
 * 目标机没有 CUDA toolkit / nvcc，但有 OpenCL（nvidia.icd，OpenCL 3.0 CUDA）。
 * 没有 CL 头文件，所以这里自带最小函数声明，直接链接 libOpenCL.so。
 *
 * 用法：
 *   ./clburn <秒数> [global_mult]
 *   ./clburn 30            # 跑 30 秒
 *
 * 编译：
 *   gcc -O2 -o clburn clburn.c -lOpenCL
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

/* ---------- 最小 OpenCL 声明（不依赖 CL/cl.h）---------- */
typedef int32_t      cl_int;
typedef uint32_t     cl_uint;
typedef uint64_t     cl_ulong;
typedef intptr_t     cl_context_properties;
typedef uint64_t     cl_bitfield;
typedef cl_bitfield  cl_device_type;
typedef cl_bitfield  cl_mem_flags;
typedef cl_bitfield  cl_command_queue_properties;

typedef struct _cl_platform_id *cl_platform_id;
typedef struct _cl_device_id   *cl_device_id;
typedef struct _cl_context      *cl_context;
typedef struct _cl_command_queue *cl_command_queue;
typedef struct _cl_program      *cl_program;
typedef struct _cl_kernel       *cl_kernel;
typedef struct _cl_mem          *cl_mem;

#define CL_SUCCESS                 0
#define CL_DEVICE_TYPE_GPU         (1 << 2)
#define CL_MEM_READ_WRITE          (1 << 0)
#define CL_MEM_COPY_HOST_PTR       (1 << 5)
#define CL_PROGRAM_BUILD_LOG       0x1183

extern cl_int clGetPlatformIDs(cl_uint, cl_platform_id *, cl_uint *);
extern cl_int clGetDeviceIDs(cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *);
extern cl_context clCreateContext(const cl_context_properties *, cl_uint,
                                  const cl_device_id *, void *, void *, cl_int *);
extern cl_command_queue clCreateCommandQueue(cl_context, cl_device_id,
                                             cl_command_queue_properties, cl_int *);
extern cl_program clCreateProgramWithSource(cl_context, cl_uint, const char **,
                                            const size_t *, cl_int *);
extern cl_int clBuildProgram(cl_program, cl_uint, const cl_device_id *,
                             const char *, void *, void *);
extern cl_int clGetProgramBuildInfo(cl_program, cl_device_id, cl_uint, size_t, void *, size_t *);
extern cl_kernel clCreateKernel(cl_program, const char *, cl_int *);
extern cl_mem clCreateBuffer(cl_context, cl_mem_flags, size_t, void *, cl_int *);
extern cl_int clSetKernelArg(cl_kernel, cl_uint, size_t, const void *);
extern cl_int clEnqueueNDRangeKernel(cl_command_queue, cl_kernel, cl_uint,
                                     const size_t *, const size_t *, const size_t *,
                                     cl_uint, const void *, void *);
extern cl_int clFinish(cl_command_queue);
extern cl_int clReleaseMemObject(cl_mem);
extern cl_int clReleaseKernel(cl_kernel);
extern cl_int clReleaseProgram(cl_program);
extern cl_int clReleaseCommandQueue(cl_command_queue);
extern cl_int clReleaseContext(cl_context);

/* ---------- kernel ---------- */
static const char *SRC =
"__kernel void burn(__global float *out, __global const float *in, int iters)\n"
"{\n"
"    int gid = get_global_id(0);\n"
"    float a = in[gid & 4095];\n"
"    float b = a + 1.0f;\n"
"    float c = a * 0.5f;\n"
"    for (int i = 0; i < iters; i++) {\n"
"        a = fma(a, b, c);\n"
"        b = fma(b, c, a);\n"
"        c = fma(c, a, b);\n"
"    }\n"
"    out[gid] = a + b + c;\n"
"}\n";

/* triad：c = a + b*s，纯带宽绑定（大数组 + 顺序访问） */
static const char *SRC_TRIAD =
"__kernel void triad(__global float4 *c, __global const float4 *a, __global const float4 *b, float s)\n"
"{\n"
"    size_t i = get_global_id(0);\n"
"    float4 av = a[i], bv = b[i];\n"
"    float4 cv;\n"
"    cv.x = av.x + bv.x * s;\n"
"    cv.y = av.y + bv.y * s;\n"
"    cv.z = av.z + bv.z * s;\n"
"    cv.w = av.w + bv.w * s;\n"
"    c[i] = cv;\n"
"}\n";


#define CHK(x) do { if ((x) != CL_SUCCESS) {                       \
    fprintf(stderr, "FAIL %s = %d (line %d)\n", #x, (int)(x), __LINE__); \
    return 1; } } while (0)

/* ---------- triad 模式：带宽绑定 ---------- */
static int run_triad(cl_device_id dev, cl_context ctx, cl_command_queue q,
                     int secs, double mb_per_buf)
{
    cl_int err;
    const char *srcs[2] = { SRC, SRC_TRIAD };
    cl_program prog = clCreateProgramWithSource(ctx, 2, srcs, NULL, &err);
    if (err != CL_SUCCESS) { fprintf(stderr,"prog fail %d\n",err); return 1; }
    err = clBuildProgram(prog, 1, &dev, NULL, NULL, NULL);
    if (err != CL_SUCCESS) {
        char log[8192]={0};
        clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
        fprintf(stderr,"build failed:\n%s\n", log); return 1;
    }
    cl_kernel k = clCreateKernel(prog, "triad", &err);
    if (err != CL_SUCCESS) { fprintf(stderr,"kernel fail %d\n",err); return 1; }

    size_t nfloat = (size_t)(mb_per_buf * 1024.0 * 1024.0 / 4.0);
    size_t n      = nfloat / 4;                 /* float4 个数 */
    size_t bytes = nfloat * sizeof(float);
    float *ha = (float*)malloc(bytes);
    float *hb = (float*)malloc(bytes);
    if (!ha || !hb) { fprintf(stderr,"host alloc fail\n"); return 1; }
    for (size_t i = 0; i < nfloat; i++) { ha[i] = 1.0f; hb[i] = 2.0f; }

    cl_mem A = clCreateBuffer(ctx, CL_MEM_READ_WRITE|CL_MEM_COPY_HOST_PTR, bytes, ha, &err);
    cl_mem B = clCreateBuffer(ctx, CL_MEM_READ_WRITE|CL_MEM_COPY_HOST_PTR, bytes, hb, &err);
    cl_mem C = clCreateBuffer(ctx, CL_MEM_READ_WRITE, bytes, NULL, &err);
    if (err != CL_SUCCESS) { fprintf(stderr,"buf fail %d\n",err); return 1; }

    float sc = 2.5f;
    CHK(clSetKernelArg(k,0,sizeof(cl_mem),&C));
    CHK(clSetKernelArg(k,1,sizeof(cl_mem),&A));
    CHK(clSetKernelArg(k,2,sizeof(cl_mem),&B));
    CHK(clSetKernelArg(k,3,sizeof(float),&sc));

    fprintf(stderr,"triad: %.0f MB/buf, N=%zu, expected traffic 3*N*4 = %.0f MB/iter\n",
            mb_per_buf, nfloat, 3.0*bytes/1048576.0);

    /* 批量提交：减少 clFinish 的同步开销，才能测到真实带宽 */
    const int BATCH = 20;
    time_t t0=time(NULL); long it=0; double total_bytes=0;
    while ((int)(time(NULL)-t0) < secs) {
        int j;
        for (j = 0; j < BATCH; j++) {
            err = clEnqueueNDRangeKernel(q,k,1,NULL,&n,NULL,0,NULL,NULL);
            if (err) { fprintf(stderr,"enqueue %d\n",err); goto tri_done; }
        }
        if (clFinish(q)!=CL_SUCCESS) { fprintf(stderr,"finish fail\n"); break; }
        it += BATCH; total_bytes += 3.0*(double)bytes*BATCH;
    }
tri_done:;
    double dt = difftime(time(NULL), t0); if (dt < 0.001) dt = 0.001;
    fprintf(stderr,"done, iters=%ld, %.1f s, BANDWIDTH = %.1f GB/s\n",
            it, dt, total_bytes/dt/1e9);

    free(ha); free(hb);
    clReleaseMemObject(A); clReleaseMemObject(B); clReleaseMemObject(C);
    clReleaseKernel(k); clReleaseProgram(prog);
    return 0;
}


int main(int argc, char **argv)
{
    int secs   = (argc > 1) ? atoi(argv[1]) : 30;
    int bTriad = (argc > 2 && strcmp(argv[2], "triad") == 0);
    int gmulti = (!bTriad && argc > 2) ? atoi(argv[2]) : 2048;
    double mb  = (bTriad && argc > 3) ? atof(argv[3]) : 512.0;
    cl_int err;

    cl_platform_id  plat;
    cl_device_id    dev;
    cl_uint         n = 0;
    CHK(clGetPlatformIDs(1, &plat, &n));
    CHK(clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, &n));

    char dname[256] = {0};
    extern cl_int clGetDeviceInfo(cl_device_id, cl_uint, size_t, void *, size_t *);
    clGetDeviceInfo(dev, 0x102B /* CL_DEVICE_NAME */, sizeof(dname), dname, NULL);
    fprintf(stderr, "device: %s\n", dname);

    cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    CHK(err);
    cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err);
    CHK(err);

    if (bTriad) {
        int rc = run_triad(dev, ctx, q, secs, mb);
        clReleaseCommandQueue(q); clReleaseContext(ctx);
        return rc;
    }

    cl_program prog = clCreateProgramWithSource(ctx, 1, &SRC, NULL, &err);
    CHK(err);
    err = clBuildProgram(prog, 1, &dev, NULL, NULL, NULL);
    if (err != CL_SUCCESS) {
        char log[8192] = {0};
        clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
        fprintf(stderr, "build failed:\n%s\n", log);
        return 1;
    }
    cl_kernel k = clCreateKernel(prog, "burn", &err);
    CHK(err);

    size_t gsz = (size_t)15 * (size_t)gmulti;   /* 15 SM */
    float *hbuf = (float *)malloc(gsz * sizeof(float));
    for (size_t i = 0; i < gsz; i++) hbuf[i] = (float)(i & 1023) * 0.001f;

    cl_mem in  = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR,
                                gsz * sizeof(float), hbuf, &err);
    CHK(err);
    cl_mem out = clCreateBuffer(ctx, CL_MEM_READ_WRITE, gsz * sizeof(float), NULL, &err);
    CHK(err);

    int iters = 200000;
    CHK(clSetKernelArg(k, 0, sizeof(cl_mem), &out));
    CHK(clSetKernelArg(k, 1, sizeof(cl_mem), &in));
    CHK(clSetKernelArg(k, 2, sizeof(int),    &iters));

    fprintf(stderr, "global=%zu iters=%d dur=%ds\n", gsz, iters, secs);

    time_t t0 = time(NULL);
    long launches = 0;
    while ((int)(time(NULL) - t0) < secs) {
        err = clEnqueueNDRangeKernel(q, k, 1, NULL, &gsz, NULL, 0, NULL, NULL);
        if (err != CL_SUCCESS) { fprintf(stderr, "enqueue err %d\n", err); break; }
        CHK(clFinish(q));
        launches++;
    }
    fprintf(stderr, "done, launches=%ld\n", launches);

    clReleaseMemObject(in); clReleaseMemObject(out);
    clReleaseKernel(k); clReleaseProgram(prog);
    clReleaseCommandQueue(q); clReleaseContext(ctx);
    free(hbuf);
    return 0;
}
