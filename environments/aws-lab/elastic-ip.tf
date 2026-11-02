variable "enable_elastic_ip" {
  type        = bool
  description = "Allocate a persistent public IPv4 address. Charged while allocated, including when EC2 is stopped."
  default     = false
}

resource "aws_eip" "lab" {
  count  = var.enable_elastic_ip ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "url-shortener-lab-static-ip"
  }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_eip_association" "lab" {
  count         = var.enable_elastic_ip ? 1 : 0
  instance_id   = aws_instance.lab.id
  allocation_id = aws_eip.lab[0].id
}
