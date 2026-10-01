pub const Box = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn empty(self: Box) bool {
        return self.width <= 0 or self.height <= 0;
    }
};
