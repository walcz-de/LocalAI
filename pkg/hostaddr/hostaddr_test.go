package hostaddr_test

import (
	"net"
	"os"
	"path/filepath"

	"github.com/mudler/LocalAI/pkg/hostaddr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Real lines from a host right after an IPv6 prefix change: the old prefix
// (97e5) is deprecated (flag 0x20), the new one (97d5) is not.
const ifInet6Sample = `200300cc7f1b97d54f288a20abf6d0eb 04 40 00 00 wlp195s0
200300cc7f1b97e5e7c4e3890143ff0e 02 40 00 20 enp193s0
200300cc7f1b97d52c90c6abbcf822fb 02 40 00 01 enp193s0
fd7a115ca1e000000000000000000002 05 80 00 80 tailscale0
00000000000000000000000000000001 01 80 10 80 lo
`

var _ = Describe("deprecated IPv6 addresses in WebRTC ICE", func() {
	var old string
	BeforeEach(func() { old = hostaddr.IfInet6Path })
	AfterEach(func() { hostaddr.IfInet6Path = old })

	It("reads exactly the deprecated addresses", func() {
		dep := hostaddr.DeprecatedIPv6(ifInet6Sample)
		Expect(dep).To(HaveLen(1))
		Expect(dep).To(HaveKey("2003:cc:7f1b:97e5:e7c4:e389:143:ff0e"))
	})

	It("drops a deprecated address and keeps current IPv6 and IPv4", func() {
		hostaddr.IfInet6Path = filepath.Join(GinkgoT().TempDir(), "if_inet6")
		Expect(os.WriteFile(hostaddr.IfInet6Path, []byte(ifInet6Sample), 0o600)).To(Succeed())
		Expect(hostaddr.NotDeprecated(net.ParseIP("2003:cc:7f1b:97e5:e7c4:e389:143:ff0e"))).To(BeFalse())
		Expect(hostaddr.NotDeprecated(net.ParseIP("2003:cc:7f1b:97d5:4f28:8a20:abf6:d0eb"))).To(BeTrue())
		Expect(hostaddr.NotDeprecated(net.ParseIP("2003:cc:7f1b:97d5:2c90:c6ab:bcf8:22fb"))).To(BeTrue(), "temporary is not deprecated")
		Expect(hostaddr.NotDeprecated(net.ParseIP("192.168.178.235"))).To(BeTrue())
	})

	It("keeps every address when the flag file cannot be read", func() {
		hostaddr.IfInet6Path = filepath.Join(GinkgoT().TempDir(), "missing")
		Expect(hostaddr.NotDeprecated(net.ParseIP("2003:cc:7f1b:97e5:e7c4:e389:143:ff0e"))).To(BeTrue())
	})
})
