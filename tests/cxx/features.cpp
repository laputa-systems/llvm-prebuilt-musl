// Exercises the libc++ / libc++abi / libunwind / compiler-rt stack. Prints one
// "ok <feature>" line per check and exits nonzero on the first failure.
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <format>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <numeric>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <typeinfo>
#include <unordered_map>
#include <variant>
#include <vector>

static void ok(const char *what) { std::cout << "ok " << what << '\n'; }
[[noreturn]] static void die(const char *what) {
    std::cout << "FAIL " << what << std::endl;
    std::exit(1);
}
#define CHECK(cond, what) do { if (!(cond)) die(what); } while (0)

// -- exceptions: unwinding runs destructors in every frame, in order ------------
static std::string trace;
struct Guard {
    char id;
    explicit Guard(char c) : id(c) {}
    ~Guard() { trace += id; }
};
struct Custom : std::runtime_error { using std::runtime_error::runtime_error; };

[[gnu::noinline]] static int level3(int depth) {
    Guard g('3');
    if (depth > 0) throw Custom("boom");
    return 1;
}
[[gnu::noinline]] static int level2(int depth) { Guard g('2'); return level3(depth) + 1; }
[[gnu::noinline]] static int level1(int depth) { Guard g('1'); return level2(depth) + 1; }

static void exceptions() {
    trace.clear();
    CHECK(level1(0) == 3 && trace == "321", "normal return runs destructors");
    trace.clear();
    bool caught = false;
    try {
        level1(1);
    } catch (const std::runtime_error &e) {  // catch by base: RTTI match across frames
        caught = std::string(e.what()) == "boom" && dynamic_cast<const Custom *>(&e) != nullptr;
    }
    CHECK(caught, "catch by base class");
    CHECK(trace == "321", "unwinding runs destructors in order");
    trace.clear();

    try {
        try {
            level1(1);
        } catch (...) {
            throw;  // rethrow through a catch-all
        }
    } catch (const Custom &) {
        CHECK(trace == "321", "destructors ran before rethrow");
    }

    std::exception_ptr ep;
    try { throw std::out_of_range("range"); } catch (...) { ep = std::current_exception(); }
    try { std::rethrow_exception(ep); }
    catch (const std::out_of_range &e) { CHECK(std::string(e.what()) == "range", "exception_ptr"); }

    try {
        std::vector<int> v;
        (void)v.at(3);
    } catch (const std::out_of_range &) {
        ok("library exception");
    }
    ok("exceptions");
}

// -- threads, thread_local, synchronization -------------------------------------
static thread_local int tls_counter = 0;
struct TlsDtor {
    std::atomic<int> *counter;
    ~TlsDtor() { if (counter) ++*counter; }
};
static std::atomic<int> tls_dtors{0};
static thread_local TlsDtor tls_obj{&tls_dtors};

static void threads() {
    constexpr int kThreads = 4, kIters = 1000;
    std::atomic<int> total{0};
    std::mutex m;
    std::condition_variable cv;
    int ready = 0;
    std::vector<std::thread> pool;
    for (int t = 0; t < kThreads; ++t) {
        pool.emplace_back([&] {
            (void)tls_obj;  // instantiate the TLS object so its destructor must run
            for (int i = 0; i < kIters; ++i) { ++tls_counter; total.fetch_add(1); }
            if (tls_counter != kIters) std::abort();  // each thread sees its own copy
            try { throw Custom("in thread"); } catch (const Custom &) {}  // unwinding off the main stack
            std::lock_guard<std::mutex> lock(m);
            ++ready;
            cv.notify_all();
        });
    }
    {
        std::unique_lock<std::mutex> lock(m);
        cv.wait(lock, [&] { return ready == kThreads; });
    }
    for (auto &t : pool) t.join();
    CHECK(total == kThreads * kIters, "atomic total");
    CHECK(tls_counter == 0, "main thread TLS untouched");
    CHECK(tls_dtors == kThreads, "thread_local destructors ran");
    ok("threads");
}

// -- standard library -----------------------------------------------------------
struct Base { virtual ~Base() = default; };
struct Derived : Base {};

static void library() {
    std::vector<int> v(100);
    std::iota(v.begin(), v.end(), 1);
    std::mt19937 rng(42);
    std::shuffle(v.begin(), v.end(), rng);
    std::sort(v.begin(), v.end());
    CHECK(std::accumulate(v.begin(), v.end(), 0) == 5050 && v.front() == 1 && v.back() == 100, "sort/accumulate");

    std::unordered_map<std::string, int> counts;
    for (const char *w : {"a", "b", "a", "c", "a"}) ++counts[w];
    std::map<std::string, int> sorted(counts.begin(), counts.end());
    std::ostringstream os;
    for (auto &[k, n] : sorted) os << k << n;
    CHECK(os.str() == "a3b1c1", "containers and streams");

    CHECK(std::format("{}-{:04x}-{:.2f}", "x", 255, 1.5) == "x-00ff-1.50", "std::format");
    std::variant<int, std::string> var = std::string("s");
    std::optional<int> none;
    CHECK(std::get<std::string>(var) == "s" && !none, "variant/optional");
    CHECK(std::filesystem::path("/a/b/c.txt").filename() == "c.txt", "std::filesystem path");

    std::unique_ptr<Base> owner = std::make_unique<Derived>();
    Base &b = *owner;
    CHECK(dynamic_cast<Derived *>(&b) && typeid(b) == typeid(Derived), "RTTI");

    static const std::string once = [] { return std::string("magic statics"); }();
    CHECK(once == "magic statics", "static initialization");
    ok("library");
}

// -- compiler-rt builtins -------------------------------------------------------
static void builtins() {
    volatile unsigned __int128 n = ((unsigned __int128)1 << 100) + 12345;
    volatile unsigned __int128 d = 1000003;
    unsigned __int128 q = n / d, r = n % d;
    CHECK(q * d + r == n, "__int128 division");
    volatile long double a = 2.0L;
    CHECK(static_cast<double>(a * a) == 4.0, "long double");
    ok("builtins");
}

struct GlobalWithDtor {
    ~GlobalWithDtor() { std::cout << "ok global destructor at exit" << std::endl; }
} global_with_dtor;

int main() {
    exceptions();
    threads();
    library();
    builtins();
    return 0;
}
