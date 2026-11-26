module wcb::binding::fcntl @private;

// Constants
const int F_GETLK64 = 5;
const int F_SETLK64 = 6;
const int F_SETLKW64 = 7;
const int O_ACCMODE = 0o003;
const int O_RDONLY = 0o0;
const int O_WRONLY = 0o1;
const int O_RDWR = 0o2;
const int O_CREAT = 0o100;
const int O_EXCL = 0o200;
const int O_NOCTTY = 0o400;
const int O_TRUNC = 0o1000;
const int O_APPEND = 0o2000;
const int O_NONBLOCK = 0o4000;
const int O_NDELAY = 2048;
const int O_SYNC = 0o4010000;
const int O_FSYNC = 1052672;
const int O_ASYNC = 0o20000;
const int F_GETLK = 5;
const int F_SETLK = 6;
const int F_SETLKW = 7;
const int F_DUPFD = 0;
const int F_GETFD = 1;
const int F_SETFD = 2;
const int F_GETFL = 3;
const int F_SETFL = 4;
const int FD_CLOEXEC = 1;
const int F_RDLCK = 0;
const int F_WRLCK = 1;
const int F_UNLCK = 2;
const int F_EXLCK = 4;
const int F_SHLCK = 8;

typedef Flock = void;
