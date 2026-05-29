package com.example.orderservice.service;

import com.example.orderservice.model.Order;
import com.example.orderservice.model.OrderRequest;
import com.example.orderservice.model.OrderStatus;
import com.example.orderservice.repository.OrderRepository;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Service
public class OrderService {

    private final OrderRepository orderRepository;

    public OrderService(OrderRepository orderRepository) {
        this.orderRepository = orderRepository;
    }

    @Transactional
    public Order create(OrderRequest request) {
        Order order = new Order();
        order.setProduct(request.product());
        order.setQuantity(request.quantity());
        order.setPriceCents((long) request.pricePerUnit() * 100L);
        order.setStatus(OrderStatus.CREATED);
        return orderRepository.save(order);
    }

    public List<Order> findAll() {
        return orderRepository.findAll(Sort.by(Sort.Direction.DESC, "createdAt"));
    }

    public Optional<Order> findById(UUID id) {
        return orderRepository.findById(id);
    }
}
