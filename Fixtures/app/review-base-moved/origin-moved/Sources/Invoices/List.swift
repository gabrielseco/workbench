struct List {
    func page() -> [Invoice] { all.sorted(by: \.date) }
}
