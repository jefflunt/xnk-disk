package volumes

import "testing"

func TestListVolumes(t *testing.T) {
	vols, err := List()
	if err != nil {
		t.Fatalf("List() failed: %v", err)
	}
	if len(vols) == 0 {
		t.Fatalf("expected at least 1 mounted volume, got 0")
	}
	for _, v := range vols {
		t.Logf("Volume: %s (%s) mount=%s fs=%s total=%d used=%d avail=%d devs=%v",
			v.Name, v.Device, v.MountPoint, v.FSType, v.TotalBytes, v.UsedBytes, v.AvailBytes, v.AllowedDevs)
		if v.TotalBytes == 0 {
			t.Errorf("volume %s has TotalBytes == 0", v.Name)
		}
	}
}
