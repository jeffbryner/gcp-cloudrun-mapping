output "cloudrun_url" {
  description = "cloud run service url"
  value       = google_cloud_run_service.default.status[0].url
}

output "load_balancer_ip" {
  value = google_compute_global_address.cloud_run_lb_address.address
}
