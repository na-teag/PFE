# Sandbox
variable "sandbox_network_cidr" {
  type    = string
  default = "192.168.100.0/24"
}

variable "sandbox_bridge" {
  type    = string
  default = "virbr-sandbox"
}

# InetSim
variable "inetsim_ip" {
  type    = string
  default = "192.168.100.2"
}

# k3s
variable "k3s_network_cidr" {
  type    = string
  default = "192.168.122.0/24"
}

variable "k3s_bridge" {
  type    = string
  default = "virbr-external"
}

variable "k3s_ip" {
  default = "192.168.122.2"
}