/* Minimal libclang client: parse a translation unit that includes a compiler
   resource header, then list the declarations from the main file. */
#include <clang-c/Index.h>
#include <stdio.h>
#include <string.h>

static enum CXChildVisitResult visit(CXCursor cursor, CXCursor parent, CXClientData data) {
    (void)parent;
    (void)data;
    if (!clang_Location_isFromMainFile(clang_getCursorLocation(cursor)))
        return CXChildVisit_Continue;
    CXString kind = clang_getCursorKindSpelling(clang_getCursorKind(cursor));
    CXString name = clang_getCursorSpelling(cursor);
    printf("%s %s\n", clang_getCString(kind), clang_getCString(name));
    clang_disposeString(kind);
    clang_disposeString(name);
    return clang_getCursorKind(cursor) == CXCursor_StructDecl ? CXChildVisit_Recurse
                                                              : CXChildVisit_Continue;
}

int main(void) {
    static const char source[] =
        "#include <stdint.h>\n"
        "struct S { int32_t field; };\n"
        "int32_t add(int32_t a, int32_t b) { return a + b; }\n";
    struct CXUnsavedFile unsaved = {"input.c", source, sizeof source - 1};
    const char *args[] = {"-x", "c"};

    CXIndex index = clang_createIndex(0, 0);
    CXTranslationUnit tu = clang_parseTranslationUnit(index, "input.c", args, 2, &unsaved, 1,
                                                      CXTranslationUnit_None);
    if (!tu) {
        fprintf(stderr, "parse failed\n");
        return 1;
    }
    unsigned diagnostics = clang_getNumDiagnostics(tu);
    for (unsigned i = 0; i < diagnostics; i++) {
        CXDiagnostic d = clang_getDiagnostic(tu, i);
        CXString text = clang_formatDiagnostic(d, clang_defaultDiagnosticDisplayOptions());
        fprintf(stderr, "diagnostic: %s\n", clang_getCString(text));
        clang_disposeString(text);
        clang_disposeDiagnostic(d);
    }
    printf("diagnostics=%u\n", diagnostics);
    clang_visitChildren(clang_getTranslationUnitCursor(tu), visit, NULL);
    clang_disposeTranslationUnit(tu);
    clang_disposeIndex(index);
    return diagnostics == 0 ? 0 : 1;
}
