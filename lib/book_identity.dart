/// Local originals and virtual series share a reserved identity range.
const localBookIdStart = 0x60000000;
bool isLocalBook(int id) => id >= localBookIdStart;

/// Custom sources cannot enter the Wenku cloud shelf or local-book store.
const sourceBookIdStart = 0x40000000;
bool isSourceBook(int id) => id >= sourceBookIdStart && id < localBookIdStart;
bool isWenkuBook(int id) => id > 0 && id < sourceBookIdStart;
