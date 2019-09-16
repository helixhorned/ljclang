
class Interface
{
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
    int getIt() final;
    void setIt(int) final;
};
