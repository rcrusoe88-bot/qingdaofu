package main

import "testing"

func TestLegacyDeleteIsDisabled(t *testing.T) {
	message := newModel("C:\\").deletePath("C:\\not-a-real-qdf-test-target")()
	result, ok := message.(deleteCompleteMsg)
	if !ok || result.err == nil {
		t.Fatal("legacy delete must fail closed")
	}
}
