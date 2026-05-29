package com.example.orderservice.model;

import java.util.List;
import java.util.Map;

/**
 * Snapshot of transaction completeness at a point in time.
 *
 * allComplete = true means every submitted order is FULFILLED and
 * the durable store is empty — safe to declare the chaos test passed.
 */
public record AuditReport(
        long total,
        Map<String, Long> byStatus,
        long pendingExecutions,
        long stuckExecutions,
        boolean allComplete,
        List<IncompleteOrder> incompleteOrders
) {
    /** Compact view of an order that has not yet reached FULFILLED. */
    public record IncompleteOrder(
            String id,
            String status,
            String executionId,
            java.time.Instant createdAt,
            java.time.Instant updatedAt
    ) {}
}
