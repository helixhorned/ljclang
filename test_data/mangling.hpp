
namespace LJClang {

struct TestStruct {
    int a;
    long b;
    double d;
};

class TestClass {
public:
    TestClass() = default;

    double testFunction(const TestStruct &t);
};

}
