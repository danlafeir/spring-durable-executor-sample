package com.example.orderservice.controller;

import com.durableexecutor.model.DurableExecution;
import com.durableexecutor.store.DurableStore;
import org.springframework.web.bind.annotation.*;

import java.time.Duration;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/admin")
public class AdminController {

    private final DurableStore durableStore;

    public AdminController(DurableStore durableStore) {
        this.durableStore = durableStore;
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
