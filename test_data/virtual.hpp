
class Interface
{
public:
    virtual int getIt() = 0;
    virtual void setIt(int) = 0;
};

class Base
{
    int getIt(bool);  // not virtual
    virtual int getIt(void *);  // virtual, but not overridden by this file
    virtual int getIt();
};

class Derived : public Base, virtual public Interface
{
    int getIt() override;  // overrides two functions (one in each base class)
};

class Final : public Derived
{
    int getIt() final { return 0; }
    void setIt(int) final {}
};

// Mis-declaration of the enum from enums.hpp to test USRs. (Wrong underlying type.)
enum BigNumbers : int;

namespace LJClangTest {
inline int GetIt(Interface &interface) {
    return interface.getIt();
}
}
