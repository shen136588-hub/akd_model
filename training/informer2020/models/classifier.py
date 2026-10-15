import torch
import torch.nn as nn

class TimeSeriesClassifier(nn.Module):
    """时序数据分类器"""
    
    def __init__(self, input_dim,classifier_type='global_avg', hidden_dims=[128, 64], 
                 dropout_rates=[0.3, 0.2], num_classes=2):
        """
        初始化分类器
        
        Args:
            input_dim: 输入特征维度
            hidden_dims: 隐藏层维度列表
            dropout_rates: dropout比率列表
            num_classes: 分类数量（二分类时设为2）
        """
        super(TimeSeriesClassifier, self).__init__()
         # 保存参数为实例属性
        self.classifier_type = classifier_type
        self.num_classes = num_classes
        self.input_dim = input_dim
        layers = []
        prev_dim = input_dim
        
        # 构建隐藏层
        for hidden_dim, dropout_rate in zip(hidden_dims, dropout_rates):
            layers.append(nn.Linear(prev_dim, hidden_dim))
            layers.append(nn.ReLU())
            layers.append(nn.Dropout(dropout_rate))
            prev_dim = hidden_dim
        
        # 输出层（对于二分类，输出1个节点）
        if num_classes == 2:
            layers.append(nn.Linear(prev_dim, 1))
        else:
            layers.append(nn.Linear(prev_dim, num_classes))
        
        self.classifier = nn.Sequential(*layers)
        
    def forward(self, x):
        """
        前向传播
        
        Args:
            x: 输入特征 [batch_size, input_dim] 或 [batch_size, seq_len, input_dim]
        
        Returns:
            分类结果
        """
        batch_size = x.size(0)
        if self.classifier_type == 'last_step':
            # 取最后一个时间步的特征
            features = x[:, -1, :]  # [batch_size, input_dim]
        elif self.classifier_type == 'global_avg':
            # 全局平均池化
            features = x.mean(dim=1)  # [batch_size, input_dim]
        elif self.classifier_type == 'flatten':
            features = encoder_output.view(batch_size, -1)    
        # 通过分类器
        logits = self.classifier(features)
        # 对于二分类，压缩输出维度
        if self.num_classes == 2:
            logits = logits.squeeze(-1)  # [batch_size]
        return logits
