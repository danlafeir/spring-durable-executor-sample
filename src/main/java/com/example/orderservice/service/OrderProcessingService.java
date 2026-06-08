package com.example.orderservice.service;

import com.github.danlafeir.durableexecutor.annotation.Durable;
import com.github.danlafeir.durableexecutor.annotation.Durable.CloseMode;
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

    @Value("${order.step-delay-ms:10000}")
    private long stepDelayMs;

    private final OrderRepository orderRepository;

    public OrderProcessingService(OrderRepository orderRepository) {
        this.orderRepository = orderRepository;
    }

    /**
     * Durable four-step order workflow.
     *
     * The @Durable aspect persists the method arguments before execution and removes
     * the record on success. If the JVM crashes mid-workflow the record survives and
     * DurableRecovery re-invokes this method on the next startup.
     */
    public void processOrder(String orderId) {
        log.info("Processing order {}", orderId);

        Order order = findOrder(orderId);
        order.setStatus(OrderStatus.VALIDATING);
        orderRepository.save(order);
        log.info("Order {} validated", orderId);

        sleep();
        updateStatus(orderId, OrderStatus.RESERVED);
        log.info("Order {} reserved", orderId);

        sleep();
        updateStatus(orderId, OrderStatus.CHARGED);
        log.info("Order {} charged", orderId);

        sleep();
        updateStatus(orderId, OrderStatus.FULFILLED);
        log.info("Order {} fulfilled", orderId);
    }

    private void sleep() {
        try {
            Thread.sleep(stepDelayMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException("Interrupted during step delay", e);
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
