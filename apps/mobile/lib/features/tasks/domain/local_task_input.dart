class LocalTaskInput {
  const LocalTaskInput({
    required this.title,
    this.description = '',
    this.completed = false,
  });

  final String title;
  final String description;
  final bool completed;
}
