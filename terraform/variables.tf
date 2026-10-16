variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "device_ids" {
  description = "IoT thing names, one per physical board"
  type        = set(string)
  default     = ["gs-001"]
}

variable "alert_email" {
  description = "Address to notify when a device goes silent"
  type        = string
}

variable "silence_minutes" {
  description = "Alarm if a device sends nothing for this long"
  type        = number
  default     = 15
}
