package com.example.orderservice.service;

import com.github.danlafeir.durableexecutor.annotation.Durable;
import com.github.danlafeir.durableexecutor.annotation.Durable.CloseMode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Component;

import java.util.concurrent.Executor;

/**
 * Durably records the intent to process an order before returning to the caller,
 * then submits the actual work to the thread pool.
 *
 * Execution lifecycle:
 *   1. @Durable aspect writes a dispatch(orderId) record to the store.
 *   2. dispatch() submits processOrder() to the executor and returns.
 *   3. @Durable aspect deletes the dispatch record (dispatch() succeeded).
 *   4. HTTP 202 response goes out.
 *   5. processOrder() runs on the executor thread; its own @Durable record
 *      covers any crash between steps 3 and completion.
 *
 * Recovery: if the pod dies before dispatch() returns the durable record
 * survives and DurableRecovery re-invokes dispatch() on the next startup,
 * which re-submits processOrder() to the executor.
 */
@Component
public class OrderDispatcher {

    private static final Logger log = LoggerFactory.getLogger(OrderDispatcher.class);

    private final OrderProcessingService processingService;
    private final Executor taskExecutor;

    public OrderDispatcher(OrderProcessingService processingService,
                           @Qualifier("taskExecutor") Executor taskExecutor) {
        this.processingService = processingService;
        this.taskExecutor = taskExecutor;
    }

    @Durable(closeMode = CloseMode.IDEMPOTENT)
    public void dispatch(String orderId) {
        taskExecutor.execute(() -> {
            try {
                processingService.processOrder(orderId);
            } catch (Exception e) {
                log.warn("Order {} processing failed — durable record kept, will retry on restart: {}",
                        orderId, e.getMessage());
            }
        });
    }
}
