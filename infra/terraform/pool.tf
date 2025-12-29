resource "libvirt_pool" "default" {
  name = "default"
  type = "dir"

  source = {
    dir = {
      path = "/var/lib/libvirt/images"
    }
  }

  target = {
    path = "/var/lib/libvirt/images"
  }
}