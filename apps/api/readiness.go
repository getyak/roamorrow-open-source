package main

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
)

// Readiness proves the private account store is reachable without returning
// connection details, credentials, identity, or private record counts.
func readiness(ping func(context.Context) error) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if ping == nil || ping(ctx) != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"status": "not_ready", "revision": buildRevision})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ready", "revision": buildRevision})
	}
}
