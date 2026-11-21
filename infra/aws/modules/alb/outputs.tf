output "alb_arn" {
  description = "The ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "The DNS Name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the load balancer (for Route 53 alias)"
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "The ARN of the Target Group"
  value       = aws_lb_target_group.app.arn
}

output "listener_arn" {
  description = "The ARN of the HTTP Listener"
  value       = aws_lb_listener.http.arn
}
