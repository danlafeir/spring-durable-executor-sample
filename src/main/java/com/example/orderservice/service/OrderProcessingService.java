package com.example.orderservice.service;

import com.durableexecutor.DurableExecutor;
import com.durableexecutor.annotation.DurableWorkflow;
import com.durableexecutor.annotation.ExecutionId;
import com.example.orderservice.model.Order;
import com.example.orderservice.model.OrderStatus;
import com.example.orderservice.repository.OrderRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.UUID;

@Service
public class OrderProcessingService {

    private static final Logger log = LoggerFactory.getLogger(OrderProcessingService.class);

    @Value("${order.fail-probability:0.0}")
    private double failProbability;

    private final OrderRepository orderRepository;
    private final DurableExecutor durableExecutor;

    public OrderProcessingService(OrderRepository orderRepository, DurableExecutor durableExecutor) {
        this.orderRepository = orderRepository;
        this.durableExecutor = durableExecutor;
    }

    /**
     * Durable four-step order workflow.
     *
     * Each step's completion is checkpointed in the durable store. If the JVM
     * crashes mid-workflow, recovery re-runs from the last incomplete step.
     * The @ExecutionId parameter receives the execution ID so it can be stored
     * on the Order entity for correlation with admin/executions.
     */
    @DurableWorkflow
    public void processOrder(String orderId, @ExecutionId String execId) {
        log.info("Processing order {} [execution={}]", orderId, execId);

        durableExecutor.step("validate", () -> {
            Order order = findOrder(orderId);
            order.setExecutionId(execId);
            order.setStatus(OrderStatus.VALIDATING);
            orderRepository.save(order);
            log.info("Order {} validated [exec={}]", orderId, execId);
        });

        durableExecutor.step("reserve", () -> {
            maybeThrow("reserve", orderId);
            updateStatus(orderId, OrderStatus.RESERVED);
            log.info("Order {} reserved", orderId);
        });

        durableExecutor.step("charge", () -> {
            maybeThrow("charge", orderId);
            updateStatus(orderId, OrderStatus.CHARGED);
            log.info("Order {} charged", orderId);
        });

        durableExecutor.step("fulfill", () -> {
            updateStatus(orderId, OrderStatus.FULFILLED);
            log.info("Order {} fulfilled", orderId);
        });
    }

    private void maybeThrow(String step, String orderId) {
        if (failProbability > 0.0 && Math.random() < failProbability) {
            throw new RuntimeException(String.format(
                    "Simulated failure at step '%s' for order %s (p=%.1f) — will retry on recovery",
                    step, orderId, failProbability));
        }
    }

    private void updateStatus(String orderId, OrderStatus status) {
        Order order = findOrder(orderId);
        order.setStatus(status);
        orderRepository.save(order);
    }

    private Order findOrder(String orderId) {
        return orderRepository.findById(UUID.fromString(orderId))
                .orElseThrow(() -> new IllegalStateException("Order not found: " + orderId));
    }
}
