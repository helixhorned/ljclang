
#include "mangling.hpp"

namespace LJClang {

double TestClass::testFunction(const TestStruct &t) {
    return t.a + t.b + t.d;
}

}
