
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

int badFunc()
{
    int i;
    return i;  // uninitialized use
}