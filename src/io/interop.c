#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_FDS 28 // From libwayland

/*
 * Call recvmsg using "buf[bufsz]". Return 0 if nothing was read or would block.
 */
ssize_t
receive_data(
    int     fd,
    char   *buf,
    size_t  bufsz,
    int    *fds, // should be able to hold MAX_FDS fds
    size_t *fds_read
)
{
    struct iovec  iov;
    struct msghdr msgh;

    char cmsg[CMSG_LEN(MAX_FDS * sizeof(int))];

    iov.iov_base = buf;
    iov.iov_len = bufsz;

    msgh.msg_name = NULL;
    msgh.msg_namelen = 0;
    msgh.msg_iov = &iov;
    msgh.msg_iovlen = 1;

    msgh.msg_control = cmsg;
    msgh.msg_controllen = sizeof(cmsg);
    msgh.msg_flags = 0;

    ssize_t r;

    do
    {
        r = recvmsg(fd, &msgh, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
    } while (r == -1 && errno == EINTR);

    if (r == -1)
    {
        if (errno == EWOULDBLOCK || errno == EAGAIN)
            return 0;
        return -1;
    }

    struct cmsghdr *cmsgh;

    for (cmsgh = CMSG_FIRSTHDR(&msgh); cmsgh != NULL;
         cmsgh = CMSG_NXTHDR(&msgh, cmsgh))
    {
        if (cmsgh->cmsg_level != SOL_SOCKET || cmsgh->cmsg_type != SCM_RIGHTS)
            continue;

        size_t sz = cmsgh->cmsg_len - CMSG_LEN(0);

        memcpy(fds + *fds_read, CMSG_DATA(cmsgh), sz);
        *fds_read += sz / sizeof(int);
    }

    return r;
}

/*
 * Call sendmsg on "buf[buflen]". Return 0 if would block.
 */
ssize_t
send_data(
    int     fd,
    char   *buf,
    size_t  buflen,
    int    *fds,
    size_t fds_len,
    size_t *fds_sent
)
{
    struct iovec  iov;
    struct msghdr msgh;

    char cmsg[CMSG_LEN(MAX_FDS * sizeof(int))];

    if (fds_len > MAX_FDS)
        fds_len = MAX_FDS;

    size_t          tocpy = fds_len * sizeof(int);
    struct cmsghdr *cmsgh = (struct cmsghdr *)cmsg;

    cmsgh->cmsg_level = SOL_SOCKET;
    cmsgh->cmsg_type = SCM_RIGHTS;
    cmsgh->cmsg_len = CMSG_LEN(tocpy);

    memcpy(CMSG_DATA(cmsgh), fds, tocpy);

    iov.iov_base = buf;
    iov.iov_len = buflen;

    msgh.msg_name = NULL;
    msgh.msg_namelen = 0;
    msgh.msg_iov = &iov;
    msgh.msg_iovlen = 1;

    msgh.msg_control = fds_len > 0 ? cmsg : NULL;
    msgh.msg_controllen = fds_len > 0 ? cmsgh->cmsg_len : 0;
    msgh.msg_flags = 0;

    ssize_t w;

    do
    {
        w = sendmsg(fd, &msgh, MSG_NOSIGNAL | MSG_DONTWAIT);
    } while (w == -1 && errno == EINTR);

    if (w == -1)
    {
        if (errno == EWOULDBLOCK || errno == EAGAIN)
            return 0;
        return -1;
    }

    *fds_sent = fds_len;

    return w;
}
