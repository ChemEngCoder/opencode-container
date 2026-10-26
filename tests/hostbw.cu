// hostbw.cu - GPU <-> host memory bandwidth and latency, per GPU.
//
// Build:  nvcc -O2 -arch=sm_86 hostbw.cu -o hostbw
// Run:    ./hostbw            (stop every other GPU workload first)
//
// Healthy PCIe 4.0 x16 with pinned memory: roughly 20-26 GB/s each way and a
// round trip of about 10-20 us for a small copy. Pageable memory is slower
// (often 5-15 GB/s) but never below 1 GB/s on a healthy system.
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    fprintf(stderr, "CUDA error %s at %s:%d\n", cudaGetErrorString(e_), __FILE__, __LINE__); \
    exit(1); } } while (0)

static double copy_gbps(void *dst, const void *src, size_t bytes, cudaMemcpyKind kind, int reps) {
    cudaEvent_t a, b;
    CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaMemcpy(dst, src, bytes, kind));              // warm-up
    CK(cudaEventRecord(a));
    for (int i = 0; i < reps; ++i) CK(cudaMemcpyAsync(dst, src, bytes, kind));
    CK(cudaEventRecord(b));
    CK(cudaEventSynchronize(b));
    float ms = 0; CK(cudaEventElapsedTime(&ms, a, b));
    CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
    return (double)bytes * reps / (ms / 1000.0) / 1e9;
}

static double small_copy_us(void *dst, const void *src, cudaMemcpyKind kind, int reps) {
    cudaEvent_t a, b;
    CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaMemcpy(dst, src, 4, kind));
    CK(cudaEventRecord(a));
    for (int i = 0; i < reps; ++i) { CK(cudaMemcpyAsync(dst, src, 4, kind)); CK(cudaStreamSynchronize(0)); }
    CK(cudaEventRecord(b));
    CK(cudaEventSynchronize(b));
    float ms = 0; CK(cudaEventElapsedTime(&ms, a, b));
    CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
    return ms * 1000.0 / reps;
}

int main() {
    const size_t bytes = 256ull << 20;   // 256 MiB
    const int reps = 10;
    int n = 0; CK(cudaGetDeviceCount(&n));
    printf("%-5s %-13s %10s %10s %10s %10s %12s\n", "GPU", "PCI bus",
           "H2D pin", "D2H pin", "H2D page", "D2H page", "4B D2H rt");
    printf("%-5s %-13s %10s %10s %10s %10s %12s\n", "", "", "GB/s", "GB/s", "GB/s", "GB/s", "us");
    for (int d = 0; d < n; ++d) {
        CK(cudaSetDevice(d));
        char bus[32]; CK(cudaDeviceGetPCIBusId(bus, sizeof bus, d));
        void *dev, *pin, *page;
        CK(cudaMalloc(&dev, bytes));
        CK(cudaMallocHost(&pin, bytes));
        page = malloc(bytes);
        if (!page) { fprintf(stderr, "malloc failed\n"); return 1; }
        for (size_t i = 0; i < bytes; i += 4096) ((char *)page)[i] = 1;   // fault pages in

        double h2d_pin  = copy_gbps(dev, pin, bytes, cudaMemcpyHostToDevice, reps);
        double d2h_pin  = copy_gbps(pin, dev, bytes, cudaMemcpyDeviceToHost, reps);
        double h2d_page = copy_gbps(dev, page, bytes, cudaMemcpyHostToDevice, 3);
        double d2h_page = copy_gbps(page, dev, bytes, cudaMemcpyDeviceToHost, 3);
        double rt_us    = small_copy_us(pin, dev, cudaMemcpyDeviceToHost, 1000);

        printf("%-5d %-13s %10.2f %10.2f %10.2f %10.2f %12.1f\n",
               d, bus, h2d_pin, d2h_pin, h2d_page, d2h_page, rt_us);
        CK(cudaFree(dev)); CK(cudaFreeHost(pin)); free(page);
    }
    return 0;
}
