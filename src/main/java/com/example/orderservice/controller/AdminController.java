package com.example.orderservice.controller;

import com.durableexecutor.model.DurableExecution;
import com.durableexecutor.store.DurableStore;
import com.example.orderservice.model.AuditReport;
import com.example.orderservice.model.AuditReport.IncompleteOrder;
import com.example.orderservice.model.Order;
import com.example.orderservice.model.OrderStatus;
import com.example.orderservice.repository.OrderRepository;
import org.springframework.web.bind.annotation.*;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@RestController
@RequestMapping("/admin")
public class AdminController {

    private final DurableStore durableStore;
    private final OrderRepository orderRepository;

    public AdminController(DurableStore durableStore, OrderRepository orderRepository) {
        this.durableStore = durableStore;
        this.orderRepository = orderRepository;
    }

    /**
     * Complete audit of transaction completeness.
     *
     * allComplete = true means every order is FULFILLED and the durable store
     * is empty — the chaos test passed. Poll this endpoint in validate.sh.
     */
    @GetMapping("/audit")
    public AuditReport getAudit() {
        List<Order> all = orderRepository.findAll();

        Map<String, Long> byStatus = all.stream().collect(
                Collectors.groupingBy(o -> o.getStatus().name(), Collectors.counting()));

        List<IncompleteOrder> incomplete = all.stream()
                .filter(o -> o.getStatus() != OrderStatus.FULFILLED)
                .map(o -> new IncompleteOrder(
                        o.getId().toString(),
                        o.getStatus().name(),
                        o.getExecutionId(),
                        o.getCreatedAt(),
                        o.getUpdatedAt()))
                .collect(Collectors.toList());

        Map<String, DurableExecution> pending = durableStore.loadAll();
        List<DurableExecution> stuck = durableStore.findStuck(Duration.ofMinutes(5));

        boolean allComplete = incomplete.isEmpty() && pending.isEmpty();

        return new AuditReport(
                all.size(),
                byStatus,
                pending.size(),
                stuck.size(),
                allComplete,
                incomplete);
    }

    /** All currently open durable executions (keyed by execution ID). */
    @GetMapping("/executions")
    public Map<String, DurableExecution> getExecutions() {
        return durableStore.loadAll();
    }

    /**
     * Executions whose lastAttemptAt is older than {@code minutes} minutes.
     * These represent orders stuck in mid-flight that have not been retried recently.
     */
    @GetMapping("/stuck")
    public List<DurableExecution> getStuck(@RequestParam(defaultValue = "5") long minutes) {
        return durableStore.findStuck(Duration.ofMinutes(minutes));
    }
}
