package com.example.orderservice.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;

/**
 * Thin async wrapper around OrderProcessingService.
 *
 * The @Async lives here (not on processOrder itself) so that
 * DurableRecovery can invoke processOrder synchronously during startup
 * without the async thread-pool dispatch interfering with the
 * RECOVERY_EXECUTION_ID ThreadLocal.
 */
@Component
public class OrderDispatcher {

    private static final Logger log = LoggerFactory.getLogger(OrderDispatcher.class);

    private final OrderProcessingService processingService;

    public OrderDispatcher(OrderProcessingService processingService) {
        this.processingService = processingService;
    }

    @Async
    public void dispatch(String orderId) {
        try {
            processingService.processOrder(orderId, null);
        } catch (Exception e) {
            log.warn("Order {} processing failed — durable record kept, will retry on restart: {}",
                    orderId, e.getMessage());
        }
    }
}
