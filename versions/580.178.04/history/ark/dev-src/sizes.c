/* 结构体尺寸自检：与 UAPI 定义逐项对照，防止打包/padding 出错 */
#include <stdio.h>
#define main p104_main_unused
#include "p104-set-mem-clock.c"
#undef main

int main(void)
{
    printf("sizeof(NVOS64_PARAMETERS)                 = %zu\n", sizeof(NVOS64_PARAMETERS));
    printf("sizeof(NVOS54_PARAMETERS)                 = %zu\n", sizeof(NVOS54_PARAMETERS));
    printf("sizeof(NV0080_ALLOC_PARAMETERS)           = %zu\n", sizeof(NV0080_ALLOC_PARAMETERS));
    printf("sizeof(NV2080_ALLOC_PARAMETERS)           = %zu\n", sizeof(NV2080_ALLOC_PARAMETERS));
    printf("sizeof(RESERVE_PERFMON_HW_PARAMS)         = %zu\n", sizeof(NV2080_CTRL_PERF_RESERVE_PERFMON_HW_PARAMS));
    printf("\n");
    printf("offsetof(NVOS54, hClient)                 = %zu\n", (size_t)&((NVOS54_PARAMETERS*)0)->hClient);
    printf("offsetof(NVOS54, hObject)                 = %zu\n", (size_t)&((NVOS54_PARAMETERS*)0)->hObject);
    printf("offsetof(NVOS54, cmd)                     = %zu\n", (size_t)&((NVOS54_PARAMETERS*)0)->cmd);
    printf("offsetof(NVOS54, flags)                   = %zu\n", (size_t)&((NVOS54_PARAMETERS*)0)->flags);
    printf("offsetof(NVOS54, params)                  = %zu\n", (size_t)&((NVOS54_PARAMETERS*)0)->params);
    printf("offsetof(NVOS54, paramsSize)              = %zu\n", (size_t)&((NVOS54_PARAMETERS*)0)->paramsSize);
    printf("offsetof(NVOS54, status)                  = %zu\n", (size_t)&((NVOS54_PARAMETERS*)0)->status);
    printf("\n");
    printf("IOCTL_RM_ALLOC                            = 0x%08lx\n", (unsigned long)IOCTL_RM_ALLOC);
    printf("IOCTL_RM_CONTROL                          = 0x%08lx\n", (unsigned long)IOCTL_RM_CONTROL);
    printf("\n期望：NVOS64=48（580 实测）, NVOS54=32, params@16, paramsSize@24, status@28\n");
    return 0;
}
