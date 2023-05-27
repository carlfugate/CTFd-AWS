# CTFd AWS Deployment

## Introduction

I recently had the opportunity to run my own mini Capture The Flag event that was hosted and focused on AWS. This was the chance that I needed to learn more about containers and Terraform so I set out to build an Infrastructure as Code deployment of CTFd on AWS.

## Design

I took a batteries included approach to this deployment primarily because when I built this it was in a sandbox environment that reset every 4 hours.  That means I would have to assume there is nothing currently deployed to use to support the CTFd environment

![CTFd AWS Architecture diagram](/images/ctfd-aws-architecture.png)

### Resource List

**Networking**

* VPC
* Route Tables
* Security Groups
* Public Subnet
* Private Subnet
* Internet Gateway
* NAT Gateway (needed for ECS to pull down the image)
* ALB


**Database**

* RDS mySQL
* Elasticache Redis

**CTFd Runtime**
* ECS Fargate Cluster / Service / Task


## Notes

At the time this was deployed, there was a patch needed for the latest version of CTFd that had been submitted but not rolled into the container image on Docker Hub thus I was deploying the previous version

## Todo List

I wouldn't call this project complete at this point but it is enough to get a functional instance of CTFd up on AWS.

Some of the things still to do...

* Make ECS multi-AZ
* Enable support for multi-AZ RDS
* Enable support for multiple Redis nodes
* Make more local variables for configuration elements
* Test vCPU/Memory config for ECS (is 1vCPU 1024?)
* Enable HTTPS support
* Change Public subnet naming
* Modularize deployment so you can pick/choose what you need
* Probably a lot of security clean up to do…
* ALB health checks were a big problem…(reminder)