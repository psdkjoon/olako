Future<void> safely(Future<void> Function() action) async {
  try {
    await action();
  } on Object {
    return;
  }
}
