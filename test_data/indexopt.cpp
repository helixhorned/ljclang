static const int C = 314159;
int var = 0;

long func1() {
    const char funcLocal = 'a';
    return var + funcLocal;
}

long func2() {
    return var + 'b';
}

extern const int D = C + 1;
extern const int E = C + 2;

template<typename T>
T Add(T a, T b) {
    return var + a + b;
}

template <typename T>
struct StructTemplate {
    StructTemplate();
    T member;
};

// NOTE: does not give an 'unused variable' warning.
static const int F = Add(4, 5);

StructTemplate<double> g;
