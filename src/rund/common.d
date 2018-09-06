module rund.common;

// returns a formatter that will print the given string.  it will print
// it surrounded with quotes if the string contains any spaces.
auto formatQuotedIfSpaces(T...)(T args) if(T.length > 0)
{
    struct Formatter
    {
        T args;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            import std.algorithm : canFind;

            bool useQuotes = false;
            foreach(arg; args)
            {
                if(arg.canFind(' '))
                {
                    useQuotes = true;
                    break;
                }
            }

            if(useQuotes)
                sink(`"`);

            foreach(arg; args)
            {
                sink(arg);
            }

            if(useQuotes)
                sink(`"`);
        }
    }
    return Formatter(args);
}
