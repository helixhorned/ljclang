
struct First
{
    int a = 1;
    long b = 2;
};

int func()
{
    First f;
    return f.a;
}

enum Fruits
{
    Apple,
    Pear = -4,
    Orange,
};

enum BigNumbers : unsigned long long
{
    Billion = 1000000000,
    Trillion = 1'000'000'000'000,
};

static_assert(Trillion == 1'000'000'000'000ULL, "");

int badFunc()
{
    int i;
    return i;  // uninitialized use
}
