struct List {
    func page(_ n: Int, size: Int = 25) -> [Invoice] {
        Array(all.dropFirst(n * size).prefix(size))
    }
}
