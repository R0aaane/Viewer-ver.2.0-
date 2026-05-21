enum SavedMediaLayoutMode { grid, list }

class SavedMediaLayout {
  const SavedMediaLayout({
    required this.mode,
    required this.columns,
    required this.childAspectRatio,
  });

  final SavedMediaLayoutMode mode;
  final int columns;
  final double childAspectRatio;

  static SavedMediaLayout fromWidth(double width) {
    if (width >= 1100) {
      return const SavedMediaLayout(
        mode: SavedMediaLayoutMode.list,
        columns: 1,
        childAspectRatio: 1,
      );
    }
    if (width >= 840) {
      return const SavedMediaLayout(
        mode: SavedMediaLayoutMode.grid,
        columns: 4,
        childAspectRatio: 0.88,
      );
    }
    if (width >= 600) {
      return const SavedMediaLayout(
        mode: SavedMediaLayoutMode.grid,
        columns: 3,
        childAspectRatio: 0.84,
      );
    }
    return SavedMediaLayout(
      mode: SavedMediaLayoutMode.grid,
      columns: width < 420 ? 1 : 2,
      childAspectRatio: width < 420 ? 1.28 : 0.82,
    );
  }
}
