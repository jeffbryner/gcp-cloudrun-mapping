output "cloudrun_url" {
  description = "cloud run service url"
  value       = google_cloud_run_v2_service.default.uri
}
