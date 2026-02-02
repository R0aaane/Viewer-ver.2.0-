class FolderHandle {
  /// Windows: directory path (e.g. C:\Users\...\Pictures)
  /// Android: treeUri (future)
  final String raw;
  const FolderHandle(this.raw);
}
