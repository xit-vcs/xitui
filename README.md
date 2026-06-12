xitui is a library for making TUIs in Zig (requires version 0.16.0).

* Includes a widget and focus system.
* Widgets are put in a union type defined by the user, rather than using dynamic dispatch.
* Supports Windows, MacOS and Linux.

For a quick way to see a dev TUI in this project, do `zig build try`. Press escape to quit.

The main projects that xitui was made for are [xit](https://github.com/xit-vcs/xit) and [haxy](https://github.com/xit-vcs/haxy).

For a smaller example project that is easier to read, see [radargit](https://github.com/xeubie/radargit), a TUI for git. Check out [main.zig](https://github.com/xeubie/radargit/blob/master/src/main.zig) to see how a project is set up.
