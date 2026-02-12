enum TagCategory {
  artist, // 作者
  series, // オリジナル / 二次創作
  mediaType, // 漫画 / イラスト
  character, // キャラクター名
  free, // 自由タグ
}

class Tag {
  final String name;
  final TagCategory category;

  const Tag({
    required this.name,
    this.category = TagCategory.free, // 既存互換
  });

  @override
  String toString() => name;
}
