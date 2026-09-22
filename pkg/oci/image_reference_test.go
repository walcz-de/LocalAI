package oci

import (
	"testing"

	"github.com/google/go-containerregistry/pkg/name"
)

// A self-hosted gallery entry looks like oci://registry:5556/repo:tag. The
// digest lookup must accept it as-is: before this normalisation the install
// and upgrade paths recorded no digest and the upgrade check reported a new
// build forever (LocalAI 4.10.0, walcz gallery, 2026-09-22).
func TestNormalizeImageReference(t *testing.T) {
	cases := map[string]string{
		"oci://registry0.example:5556/localai-backends:v1-vllm": "registry0.example:5556/localai-backends:v1-vllm",
		"quay.io/go-skynet/local-ai-backends:latest-cpu":        "quay.io/go-skynet/local-ai-backends:latest-cpu",
	}
	for in, want := range cases {
		got := normalizeImageReference(in)
		if got != want {
			t.Fatalf("normalizeImageReference(%q) = %q, want %q", in, got, want)
		}
		if _, err := name.ParseReference(got); err != nil {
			t.Fatalf("normalised reference %q does not parse: %v", got, err)
		}
	}
	if _, err := name.ParseReference("oci://registry0.example:5556/x:y"); err == nil {
		t.Fatalf("expected the raw oci:// form to be unparseable — otherwise this normalisation is moot")
	}
}
