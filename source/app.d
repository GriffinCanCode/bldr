import std.stdio;
import infrastructure.tools;
import core.stdc.stdlib : exit;
import builder_entry;

version(BuilderLib) {
    // No main function for library build
} else {
void main(string[] args)
    {
        exit(runBuilder(args));
    }
}
