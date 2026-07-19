package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func main() {
	sockName := flag.String("sock", "", "ABSTRACT unix socket name to receive TUN fd (SCM_RIGHTS)")
	target := flag.String("target", "", "path to real tun2socks binary")
	proxy := flag.String("proxy", "", "proxy url, e.g. socks5://127.0.0.1:10808")
	mtu := flag.Int("mtu", 1500, "TUN MTU")
	logLevel := flag.String("loglevel", "info", "tun2socks log level")
	flag.Parse()

	if *sockName == "" || *target == "" || *proxy == "" {
		fmt.Fprintf(os.Stderr, "Usage: %s -sock <name> -target <path> -proxy <url> [-mtu 1500] [-loglevel info]\n", os.Args[0])
		os.Exit(2)
	}

	// 1) Listen on ABSTRACT unix socket: name starts with '\x00'
	lfd, err := unix.Socket(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Fatalf("socket: %v", err)
	}
	defer unix.Close(lfd)

	addr := &unix.SockaddrUnix{Name: "\x00" + *sockName}
	if err := unix.Bind(lfd, addr); err != nil {
		log.Fatalf("bind: %v", err)
	}
	if err := unix.Listen(lfd, 1); err != nil {
		log.Fatalf("listen: %v", err)
	}

	// 2) Accept connection and receive FD via SCM_RIGHTS
	_ = unix.SetNonblock(lfd, false)
	cfd, _, err := unix.Accept(lfd)
	if err != nil {
		log.Fatalf("accept: %v", err)
	}
	defer unix.Close(cfd)

	// timeout, чтобы не зависать бесконечно
	_ = unix.SetsockoptTimeval(cfd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &unix.Timeval{Sec: 5, Usec: 0})

	buf := make([]byte, 1)
	oob := make([]byte, unix.CmsgSpace(4*4))

	_, oobn, _, _, err := unix.Recvmsg(cfd, buf, oob, 0)
	if err != nil {
		log.Fatalf("recvmsg: %v", err)
	}

	msgs, err := unix.ParseSocketControlMessage(oob[:oobn])
	if err != nil {
		log.Fatalf("parse cmsg: %v", err)
	}

	var fds []int
	for _, m := range msgs {
		got, e := unix.ParseUnixRights(&m)
		if e == nil && len(got) > 0 {
			fds = append(fds, got...)
		}
	}

	if len(fds) == 0 {
		log.Fatalf("no fd received")
	}

	tunFD := fds[0]

	// 3) Ensure FD is usable: clear CLOEXEC, set blocking
	// close-on-exec off
	if _, e := unix.FcntlInt(uintptr(tunFD), unix.F_SETFD, 0); e != nil {
		log.Printf("fcntl(F_SETFD,0) warning: %v", e)
	}
	_ = unix.SetNonblock(tunFD, false)

	// 4) Dup to fixed fd number for tun2socks
	const fixedFD = 100
	if err := unix.Dup2(tunFD, fixedFD); err != nil {
		log.Fatalf("dup2: %v", err)
	}
	_ = unix.Close(tunFD)

	time.Sleep(50 * time.Millisecond)

	// 5) Exec real tun2socks with fixed fd
	argv := []string{
		*target,
		"-device", fmt.Sprintf("fd://%d", fixedFD),
		"-proxy", *proxy,
		"-mtu", fmt.Sprintf("%d", *mtu),
		"-loglevel", *logLevel,
	}

	env := os.Environ()
	if err := syscall.Exec(*target, argv, env); err != nil {
		log.Fatalf("exec: %v", err)
	}
}
