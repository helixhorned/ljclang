
struct First
{
    int a = 1;
    long b = 2;

    // ref-qualifiers
    void refQualNone();
    void refQualLValue() &;
    void refQualRValue() &&;
};

inline int func()
{
    First f;
    return f.a;
}

enum Fruits
{
    Apple,
    Pear,
};

inline int badFunc(const char *, ...)
{
    int i;
    return i;  // uninitialized use
}

// Declaration of the enum from enums.hpp to test USRs.
enum BigNumbers : unsigned long long;
